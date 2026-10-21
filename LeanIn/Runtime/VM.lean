module

public import LeanIn.Runtime.Net
public import LeanIn.Runtime.Io
public import LeanIn.Runtime.Clock


public section
/-!
# A defunctionalizing task monad (experiment)

`VM` is a free machine over the engine's effects — reactor (`recv`/`send`/`sendAll`/`close`), timers
(`recvTimeout`, `sleep`), an `IO` leaf (`ioE`) for what the engine's own effects do not cover, a raise/catch
pair (`throwE`/`tryE`) for the failure a connection loop answers rather than dies on, and a **separate abort
channel** (`abortE`/`tryAbortE`) for a transport failure. A client writes ordinary `do`; the incremental
interpreter drives it by **raw resume**: socket completions on the loop thread, sub-computation completions
through a raw cell, never a `Join`/`Item`/inject.

**Two failure channels, and why.** An ordinary raise is the application's: a connection loop answers it, a
middleware may turn it into a response, and `tryE` catches it wherever it happens. A transport failure is the
connection's own cancellation — the peer closed its write side mid-body, or a send could not reach a socket that
is gone. It does **not** mean the peer cannot read: a half-closed peer may still read, and bytes already sent
stand, but the request cannot be completed on that connection, so the driver closes it rather than attempting
another response. It therefore does not travel the raise channel at all: a raw transport operation under
`abortOnFailure` delivers its own failure to the abort
channel, and an abort passes every `tryE`/`attempt` unchanged, synchronously and after any resume. Only
`tryAbort` handles one, and the request boundary uses that to turn the abort into a tagged `Outcome` the driver
reads.

`runAsync` — run a machine to a raw cell and park the caller's continuation on it — makes it a concurrency
engine rather than a socket driver. On a single carrier it is *cooperative*: a spawned machine's effects resume
on the same loop thread as the parent's, and its completion resolves the raw cell the awaiter is parked on —
no second carrier, no parallelism, the single-carrier design.

**The same-type shape.** `runAsync` is uniform at `α` — the spawned machine, its cell, and the
parent share one result type. That is the form a *parameterized* `VM α` admits without an existential: a fully
general `spawn : VM β → VM (RawCell β)` needs an indexed `VM : Type → Type` whose existential constructors hit
Lean's predicativity wall (an indexed free monad whose effects bind types and mention the monad or functions
into it), which this session's attempts confirmed is a real obstacle, not a naming detail. The same-type form
covers the common concurrency patterns — spawn a handler and join it, race two computations of one type —
which is most of what a connection loop does. A worker producing a *different* type writes it into a shared
cell the parent owns, returning `Unit` both ways.

The representation is the parameterized free machine: `Monad.bind` is `partial` (O(depth) re-wrap, fine for
connection loops), and `runK` interprets incrementally by raw resume.
-/

namespace LeanIn.Runtime

/-- **A raw completion cell**: a result slot plus the raw waiters to run on resolution, first-wins. The task
analogue of the socket layer's raw delivery — a `resolve` runs its waiters directly on the resolving thread,
never through a `Join` cell's `Item`.

**Single-carrier, so a plain `IO.Ref`, not a mutex.** Every access — a spawned machine's `resolve` on
completion, a parent's `await` — runs on the one carrier thread, so there is no contention to exclude. And it
is correct, not merely cheaper: a carrier's step runs to its next effect without yielding, so the
read-modify-write in `resolve`/`await` is atomic on that thread — no other computation can interleave between
the `get` and the `set`. A `Std.Mutex` would buy an atomic lock for a race that cannot occur, and would
misstate the design (it would imply a second thread could hold the cell). If the engine ever grows a second
carrier, this becomes a mutex again; today it is not. -/
structure RawCellState (α : Type) where
  result : Option α := none
  waiters : List (α → IO Unit) := []

structure RawCell (α : Type) where
  state : IO.Ref (RawCellState α)

namespace RawCell

def new : IO (RawCell α) := return ⟨← IO.mkRef {}⟩

/-- Resolve, first-wins: a later resolve is ignored (a race's loser, or a redundant completion). -/
def resolve (cell : RawCell α) (v : α) : IO Unit := do
  let st ← cell.state.get
  match st.result with
  | some _ => pure ()
  | none   =>
    cell.state.set { st with result := some v, waiters := [] }
    for w in st.waiters do w v

/-- Park a raw waiter, or run it now if the cell already holds a value. -/
def await (cell : RawCell α) (resume : α → IO Unit) : IO Unit := do
  let st ← cell.state.get
  match st.result with
  | some v => resume v
  | none   => cell.state.set { st with waiters := st.waiters ++ [resume] }

end RawCell

/-- **Select, raw**: first-wins over two completion cells of one type. The first cell to resolve resumes the
waiter with its index and value; the other's resolution is ignored (its waiter stays registered and no-ops
when it fires). Registration order is the tie rule — the first cell registers first, so an already-resolved
first handle wins — as `Task.select` documents. -/
def selectRaw (h0 : RawCell α) (h1 : RawCell α) (resume : Nat × α → IO Unit) : IO Unit := do
  let won ← IO.mkRef false
  let once (i : Nat) : α → IO Unit := fun v => do
    let first ← won.modifyGet fun b => if b then (false, b) else (true, true)
    if first then resume (i, v)
  RawCell.await h0 (once 0)
  RawCell.await h1 (once 1)

/-- **How a machine ended under its scope.** The request boundary gets an ordinary error and a transport abort
as *values*, so it can distinguish them: an ordinary error is answered, an abort is only closed. -/
inductive Outcome (α : Type) where
  /-- The machine produced a value. -/
  | ok (v : α)
  /-- The machine raised an ordinary `IO.Error` no catch answered. -/
  | error (e : IO.Error)
  /-- A transport operation aborted the machine; `reason` is the transport failure that did it. -/
  | aborted (reason : IO.Error)

/-- **A cancellation scope**: one token, the timers currently waiting under it, the child scopes, and the
cleanup actions a request registered. Cancellation sets the token and runs the registered timer retirements;
the computation aborts at its next interpreter step or at the timer it was parked on. `exit` runs the cleanup
list exactly once, whether the computation succeeded, raised, or aborted. -/
structure ScopeState where
  /-- Live timers: identity and the action that retires one. -/
  waits : List (Nat × IO Unit) := []
  /-- Actions run once when the scope exits. -/
  exits : List (IO Unit) := []
  /-- Child cancel actions, cancelled with the parent. -/
  children : List (Nat × IO Unit) := []
  nextId : Nat := 0
  exited : Bool := false
  /-- The cancellation abort has been delivered; a late step or timer must not deliver a second. -/
  cancelDelivered : Bool := false

structure Scope where
  id : Nat := 0
  cancel : Task.Cancel
  /-- The parent's state cell, for unregistering on exit. -/
  parent : Option (Std.Mutex ScopeState) := none
  state : Std.Mutex ScopeState

namespace Scope

def new : IO Scope := do
  return { cancel := ← Task.Cancel.new, state := ← Std.Mutex.new ({} : ScopeState) }

/-- Register a timer retirement; the returned action removes it (a normal fire or abort). -/
def addWait (s : Scope) (retire : IO Unit) : IO (IO Unit) := do
  let id ← s.state.atomically do
    let st ← get
    let id := st.nextId
    set { st with nextId := id + 1, waits := (id, retire) :: st.waits }
    return id
  return (s.state.atomically (modify (fun st => { st with waits := st.waits.filter (·.1 != id) })) : IO Unit)

/-- Register cleanup to run on the scope's single exit. -/
def onExit (s : Scope) (act : IO Unit) : IO Unit :=
  s.state.atomically (modify (fun st => { st with exits := act :: st.exits }))

/-- Cancel: set the token, take the live timers and children, then retire the timers and cancel the children.
Their abort continuations (or the interpreter's next step) deliver the abort; `exit` then runs cleanup once. -/
def cancelNow (s : Scope) : IO Unit := do
  Task.Cancel.set s.cancel
  let (waits, children) ← s.state.atomically do
    let st ← get
    set { st with waits := [], children := [] }
    return (st.waits.map (·.2), st.children.map (·.2))
  for retire in waits do retire
  for cancelChild in children do cancelChild

/-- A child scope: it is cancelled with its parent and unregisters itself when it exits. -/
def child (p : Scope) : IO Scope := do
  let c ← Scope.new
  let id ← p.state.atomically do
    let st ← get
    let id := st.nextId
    set { st with nextId := id + 1, children := (id, c.cancelNow) :: st.children }
    return id
  return { c with id, parent := some p.state }

/-- First request for the cancellation abort. False once one was delivered, so a step and a timer cannot both
run the abort continuation. -/
def claimCancel (s : Scope) : IO Bool := do
  s.state.atomically do
    let st ← get
    if st.cancelDelivered then return false
    set { st with cancelDelivered := true }
    return true

/-- Run the cleanup list once. A second call, whether from another terminal path or an explicit call, does
nothing. -/
def exit (s : Scope) : IO Unit := do
  let exits? ← s.state.atomically do
    let st ← get
    if st.exited then return none
    set { st with exited := true, waits := [], children := [] }
    return some st.exits
  match exits? with
  | none => pure ()
  | some exits =>
      for act in exits do act
      match s.parent with
      | none => pure ()
      | some p =>
          p.atomically (modify (fun st => { st with children := st.children.filter (·.1 != s.id) }))

end Scope

/-- A defunctionalized computation. -/
inductive VM (α : Type) where
  | pure (v : α)
  | recvE (c : Conn) (k : Option ByteArray → VM α)
  | recvTimeoutE (c : Conn) (clock : Clock) (d : Std.Time.Millisecond.Offset)
      (k : Option (Option ByteArray) → VM α)
  | sendE (c : Conn) (bs : ByteArray) (k : VM α)
  | sendAllE (c : Conn) (chunks : Array ByteArray) (k : VM α)
  | closeE (c : Conn) (k : VM α)
  | sleepE (clock : Clock) (d : Std.Time.Millisecond.Offset) (k : VM α)
  /-- An ordinary `IO` action, as a leaf: whatever the engine's own effects do not cover, a client still runs.
  Carried in continuation-passing form -- a value continuation, an ordinary-error continuation and an abort
  continuation rather than `IO α` -- because that is what makes the node rebindable: with the result in an
  output position, `bind` at another type could not rebuild it, whereas here the type appears only in
  continuation positions, exactly as it does for the other effects. The error continuation is what lets a
  `bind` thread a `tryE`'s catch through the leaf, and the abort continuation is what lets an abort raised in
  the leaf's continuation stay an abort instead of being caught as a raise. -/
  | ioLeaf (act : Option Scope → (α → IO Unit) → (IO.Error → IO Unit) → (IO.Error → IO Unit) → IO Unit)
  /-- A raise, and its catch. A connection loop answers a failed handler rather than dying with it. -/
  | throwE (err : IO.Error)
  | tryE (body : VM α) (handler : IO.Error → VM α)
  /-- An abort: the transport's own cancellation. It is not a raise — `throwE`'s catch and `attempt` never see
  it — so nothing may answer a cancelled request as if it were an application failure. -/
  | abortE (reason : IO.Error)
  /-- **An abort scope**: an abort in the enclosed machine becomes the handler's to run, exactly as `tryE` does
  for raises. A request boundary uses it to turn cancellation into a tagged `Outcome`; nothing narrower does. -/
  | tryAbortE (body : VM α) (handler : IO.Error → VM α)
  /-- A nested cancellation scope: create it (as a child when one is already active), publish it, run the
  body, and exit it on every terminal path. -/
  | scopeE (onScope : Scope → IO Unit) (body : VM α)
  | empty

namespace VM

/-- **The incremental interpreter**, in three-continuation form: `kok` takes the final value, `kerr` takes a
raise to the innermost catch a `tryE` opened, and `kab` takes an abort. All three travel in every effect's
callback — and, because `ioLeaf`'s stored action receives *all three*, through a `bind`'s rewritten `IO`
continuation too — so a raise is caught *wherever* it happens: synchronously, after a suspension, or behind a
`monadLift`. An abort is never caught by those: `kerr` is what `tryE` and `attempt` replace, `kab` is what only
`tryAbort` replaces, so a cancellation passes every ordinary catch on its way to the request boundary. The
top-level entries pass `throw` for both, so a `VM` nobody scopes fails loudly where it resumes. `partial`
because a connection loop has no bound. -/
partial def runK (scope : Option Scope) (m : VM α) (kok : α → IO Unit) (kerr : IO.Error → IO Unit)
    (kab : IO.Error → IO Unit) : IO Unit := do
  match scope with
  | some s =>
      if ← Task.Cancel.isSet s.cancel then
        if ← s.claimCancel then
          kab (.userError "VM: the scope was cancelled")
          return
  | none => (Pure.pure () : IO Unit)
  match m with
  | .pure v => kok v
  | .recvE c kk => Io.recvRaw c 65536 (fun
    | .ok d    => runK scope (kk d) kok kerr kab
    | .error e => kerr e)
  | .sendE c bs kk => Io.sendRaw c bs (fun
    | .ok _    => runK scope kk kok kerr kab
    | .error e => kerr e)
  | .sendAllE c cs kk => Io.sendAllRaw c cs (fun
    | .ok _    => runK scope kk kok kerr kab
    | .error e => kerr e)
  | .recvTimeoutE c cl d kk => Io.recvTimeoutRaw c cl.schedule d 65536 (fun
    | none            => runK scope (kk none) kok kerr kab
    | some (.ok d)    => runK scope (kk (some d)) kok kerr kab
    | some (.error e) => kerr e)
  | .sleepE cl d kk => do
    let cancel ← match scope with
      | some s => (Pure.pure s.cancel : IO Task.Cancel)
      | none   => Task.Cancel.new
    let unregRef ← IO.mkRef ((Pure.pure () : IO Unit))
    let unregister : IO Unit := do (← unregRef.get)
    let fire : IO Unit := do
      unregister
      runK scope kk kok kerr kab
    let onCancel : IO Unit := do
      unregister
      match scope with
      | some s => if ← s.claimCancel then kab (.userError "VM: the sleep was cancelled by its scope")
      | none   => kab (.userError "VM: the sleep was cancelled")
    let retire ← cl.scheduleCancel d cancel fire onCancel
    match scope with
    | some s =>
        unregRef.set (← s.addWait retire)
        -- A cancel that took the wait list before this registration still owns the token.
        if ← Task.Cancel.isSet cancel then retire
    | none => (Pure.pure () : IO Unit)
  | .closeE c kk => do
    if (← Io.closeRaw c) then
      runK scope kk kok kerr kab
    else
      kerr (.userError "Io.closeRaw: the loop refused a close submission")
  | .ioLeaf act => act scope kok kerr kab
  | .throwE e => kerr e
  | .tryE b h => runK scope b kok (fun e => runK scope (h e) kok kerr kab) kab
  | .abortE r => kab r
  | .tryAbortE b h => runK scope b kok kerr (fun r => runK scope (h r) kok kerr kab)
  | .scopeE onScope body => do
      let sc ← match scope with
        | some p => Scope.child p
        | none   => Scope.new
      onScope sc
      runK (some sc) body
        (fun v => do sc.exit; kok v)
        (fun e => do sc.exit; kerr e)
        (fun r => do sc.exit; kab r)
  | .empty    => (Pure.pure () : IO Unit)

/-- A default for the `partial` bind's unreachable fallback — never produced by a real machine. -/
instance : Inhabited (VM α) where
  default := .empty

protected partial def bind : VM α → (α → VM β) → VM β
  | .pure v, f => f v
  | .recvE c k, f => .recvE c (fun r => VM.bind (k r) f)
  | .recvTimeoutE c cl d k, f => .recvTimeoutE c cl d (fun r => VM.bind (k r) f)
  | .sendE c bs k, f => .sendE c bs (VM.bind k f)
  | .sendAllE c cs k, f => .sendAllE c cs (VM.bind k f)
  | .closeE c k, f => .closeE c (VM.bind k f)
  | .sleepE cl d k, f => .sleepE cl d (VM.bind k f)
  | .ioLeaf act, f =>
    .ioLeaf (fun scope kok kerr kab =>
      act scope (fun v => VM.runK scope (f v) kok kerr kab) kerr kab)
  | .throwE e, _ => .throwE e
  | .tryE b h, f => .tryE (VM.bind b f) (fun e => VM.bind (h e) f)
  | .abortE r, _ => .abortE r
  | .tryAbortE b h, f => .tryAbortE (VM.bind b f) (fun r => VM.bind (h r) f)
  | .scopeE on body, f => .scopeE on (VM.bind body f)
  | .empty, _ => .empty

instance : Monad VM where
  pure := .pure
  bind := VM.bind

/-- The lifted action's outcome as a value: its own `IO` failure becomes `Except.error`, which the leaf then
takes to the error continuation. `EIO.catchExceptions` names the monad, so the catch is the `IO` one rather than
whichever `MonadExcept` instance a `try` would search for. -/
def liftStep (act : IO α) : IO (Except IO.Error α) :=
  EIO.catchExceptions (Except.ok <$> act)
    (fun (e : IO.Error) => (Pure.pure (Except.error e) : BaseIO (Except IO.Error α)))

/-- `IO` as a `VM` leaf, so a client's ordinary IO runs in the same machine. The leaf's own failure takes the
error continuation, exactly as a `throwE` does. The catch surrounds the **lifted action only**: the value
continuation then runs outside it, so a failure raised downstream — including an abort on its way to the
request scope — is never reclassified as this leaf's ordinary error. -/
instance : MonadLift IO VM where
  monadLift act := .ioLeaf (fun _ kok kerr _ => do
    match ← liftStep act with
    | .ok v => kok v
    | .error e => kerr e)

/-- Raise and catch, for the failure a connection answers rather than dies on. -/
instance : MonadExcept IO.Error VM where
  throw err := .throwE err
  tryCatch body handler := .tryE body handler

/-- **Attempt**: run `m`, turning a raise into an `Except` value — *wherever* the raise happens, before or
after a suspension: the interpreter carries the catch's stack in every effect's callback, so a handler that
reads a backend and then fails is caught exactly as one that fails at once. An abort is not a raise and is not
caught here. -/
def attempt (m : VM α) : VM (Except IO.Error α) := do
  try
    return .ok (← m)
  catch e => return .error e

/-- **Abort**: the transport's own cancellation, which no `throwE`, `tryE` or `attempt` catches. Only `tryAbort`
handles it. -/
def abort (reason : IO.Error) : VM α := .abortE reason

/-- **The transport wrapper**: one raw completion whose *own* failure is delivered to the abort channel, so it
is an abort rather than a raise the nearest `tryE` would catch. `act` receives the value continuation and that
failure continuation; it is the only place the classification lives, so a `bind`'s later steps — including a
client's `throwE` — run with the ordinary error channel and stay ordinary. -/
def abortOnFailure (act : (α → IO Unit) → (IO.Error → IO Unit) → IO Unit) : VM α :=
  .ioLeaf (fun _ kok _kerr kab => act kok kab)

/-- **A read with a deadline as the transport's**: a raw read failure aborts at the read. The caller still
decides what a deadline or an end of stream means — the streaming body reader aborts both. -/
def recvTimeoutTransport (c : Conn) (clock : Clock) (d : Std.Time.Millisecond.Offset) :
    VM (Option (Option ByteArray)) :=
  abortOnFailure fun kok fail => Io.recvTimeoutRaw c clock.schedule d 65536 (fun
    | none            => kok none
    | some (.ok data) => kok (some data)
    | some (.error e) => fail e)

/-- **A send as the transport's**: a failed raw send aborts. -/
def sendTransport (c : Conn) (bs : ByteArray) : VM Unit :=
  abortOnFailure fun kok fail => Io.sendRaw c bs (fun
    | .ok _    => kok ()
    | .error e => fail e)

/-- **A batched send as the transport's**: a failed raw send aborts. -/
def sendAllTransport (c : Conn) (chunks : Array ByteArray) : VM Unit :=
  abortOnFailure fun kok fail => Io.sendAllRaw c chunks (fun
    | .ok _    => kok ()
    | .error e => fail e)

/-- **An abort scope**: run `m`, handing an abort to `handler` instead of letting it reach the runner. Without
it, an abort has no catch at all and the machine fails loudly where it resumes. -/
def tryAbort (m : VM α) (handler : IO.Error → VM α) : VM α := .tryAbortE m handler

/-- **A cancellation scope around `m`.** The scope is created when the node runs, published through
`onScope`, and exited exactly once whether `m` returns, raises or aborts. A scope inside another is created as
its child, so the parent's cancellation reaches it. -/
def withScope (onScope : Scope → IO Unit) (m : VM α) : VM α := .scopeE onScope m



/-- **The request scope**: run `m` and tag how it ended, so a driver distinguishes an ordinary error, which it
may answer, from a transport abort, which it may only close. -/
def requestScope (m : VM α) : VM (Outcome α) :=
  VM.tryAbort (do
    match ← VM.attempt m with
    | .ok v => return .ok v
    | .error e => return .error e)
    (fun reason => return .aborted reason)

/-- The effects, as the operations a client writes with `←`. -/
def recv (c : Conn) : VM (Option ByteArray) := .recvE c .pure
/-- **Read with a deadline**: `none` if `d` elapses first (the peer stalled), `some result` for the read. -/
def recvTimeout (c : Conn) (clock : Clock) (d : Std.Time.Millisecond.Offset) :
    VM (Option (Option ByteArray)) := .recvTimeoutE c clock d .pure
def send (c : Conn) (bs : ByteArray) : VM Unit := .sendE c bs (.pure ())
def sendAll (c : Conn) (chunks : Array ByteArray) : VM Unit := .sendAllE c chunks (.pure ())
def sleep (clock : Clock) (d : Std.Time.Millisecond.Offset) : VM Unit := .sleepE clock d (.pure ())
def close (c : Conn) : VM Unit := .closeE c (.pure ())

/-- An `IO` action as a leaf with a value continuation and an ordinary-error continuation. The machine's abort
channel passes through the leaf untouched, so a leaf's failure is an ordinary raise unless a `transport` scope
is what encloses it. -/
def ioE (act : (α → IO Unit) → (IO.Error → IO Unit) → IO Unit) : VM α :=
  .ioLeaf (fun _ kok kerr _ => act kok kerr)

/-- **Run a connection loop** (fire-and-forget: the result is `Unit`; a raise nobody catches fails where the
machine resumes, and so does an abort nobody scopes — both are `throw`s here rather than a silent close). -/
def run (m : VM Unit) : IO Unit :=
  runK none m (fun _ => (Pure.pure () : IO Unit)) (fun e => throw e) (fun r => throw r)

/-- **Run a machine to a raw cell** (drive it, resolve the cell on completion; a raise nobody catches fails
where the machine resumes, and an abort nobody scopes fails there too). -/
def runToCell (m : VM α) (cell : RawCell α) : IO Unit :=
  runK none m (fun v => RawCell.resolve cell v) (fun e => throw e) (fun r => throw r)

/-- **Spawn a machine and await its result** (run it to a fresh cell, park `resume` on it). This is the effect
an `async` uses to await a sub-computation — a handler that itself suspends: `runToCell` starts the
machine (its effects resume on the loop thread) and `RawCell.await` parks the caller's continuation, which the
machine's final `resolve` fires. A machine wrapped in `requestScope` resolves the cell on success, ordinary error and
abort alike, because all three are values it produced; an unscoped abort has no value to resolve and fails
loudly where the machine resumes. -/
def runAsync (m : VM α) (resume : α → IO Unit) : IO Unit :=
  match m with
  | .pure v => resume v      -- nothing to suspend on: no cell, no park
  | _ => do
    let cell ← RawCell.new
    runToCell m cell
    RawCell.await cell resume

/-- Run a machine under a scope and return its result, exiting the scope on every terminal path. An
ordinary raise is re-raised after the cleanup; an abort no `tryAbort` handled is likewise re-raised. -/
def runScoped (scope : Scope) (m : VM α) : IO α := do
  let cell ← RawCell.new
  runK (some scope) m
    (fun v => do scope.exit; RawCell.resolve cell v)
    (fun e => do scope.exit; throw e)
    (fun r => do scope.exit; throw r)
  let out ← IO.mkRef (none : Option α)
  RawCell.await cell (fun v => out.set (some v))
  match ← out.get with
  | some v => return v
  | none => throw (.userError "VM.runScoped: the scope exited without a value")

/-- Create a scope, hand it to the caller, then run the machine under it. This is the entry a server uses
to publish a request's scope for later cancellation without taking the scope away from the machine. -/
def runScopedWith (onScope : Scope → IO Unit) (m : VM α) : IO α := do
  let scope ← Scope.new
  onScope scope
  runScoped scope m

/-- **Run a machine under a cancellation scope.** The scope's token is read at every interpreter step and its
registered timer retirements are run by `cancelNow`; the terminal continuation — value, raise or abort — runs
the scope's cleanup exactly once. Wrap the machine in `requestScope` when the caller wants cancellation and
transport aborts as an `Outcome` rather than a throw. -/
def runAsyncScoped (scope : Scope) (m : VM α) (resume : α → IO Unit) : IO Unit :=
  match m with
  | .pure v => do
      scope.exit
      resume v
  | _ => do
      let cell ← RawCell.new
      runK (some scope) m
        (fun v => do scope.exit; RawCell.resolve cell v)
        (fun e => do scope.exit; throw e)
        (fun r => do scope.exit; throw r)
      RawCell.await cell resume

end VM

end LeanIn.Runtime

end
