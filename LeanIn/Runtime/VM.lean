import LeanIn.Runtime.Net
import LeanIn.Runtime.Io
import LeanIn.Runtime.Clock

/-!
# A defunctionalizing task monad (experiment)

`VM` is a free machine over the engine's effects — reactor (`recv`/`send`/`sendAll`/`close`), timers
(`recvTimeout`, `sleep`), an `IO` leaf (`ioE`) for what the engine's own effects do not cover, and a raise/catch
pair (`throwE`/`tryE`) for the failure a connection loop answers rather than dies on. A client writes ordinary
`do`; the incremental interpreter drives it by **raw resume**: socket completions on the loop thread,
sub-computation completions through a raw cell, never a `Join`/`Item`/inject.

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
  Carried in continuation-passing form -- a value continuation and an error continuation rather than `IO α` --
  because that is what makes the node rebindable: with the result in an output position, `bind` at another type
  could not rebuild it, whereas here the type appears only in continuation positions, exactly as it does for
  the other effects. The error continuation is what lets a `bind` thread a `tryE`'s catch through the leaf. -/
  | ioE (act : (α → IO Unit) → (IO.Error → IO Unit) → IO Unit)
  /-- A raise, and its catch. A connection loop answers a failed handler rather than dying with it. -/
  | throwE (err : IO.Error)
  | tryE (body : VM α) (handler : IO.Error → VM α)
  | empty

namespace VM

/-- **The incremental interpreter**, in two-continuation form: `kok` takes the final value, `kerr` takes a
raise to the innermost catch a `tryE` opened. The pair travels in every effect's callback — and, because
`ioE`'s stored action receives *both*, through a `bind`'s rewritten `IO` continuation too — so a raise is
caught *wherever* it happens: synchronously, after a suspension, or behind a `monadLift`. A transport failure
is a raise here: the raw layer delivers a failed read or write as an error, and it becomes the `kerr` path,
never an ordinary end of stream. The top-level entries pass `throw` for `kerr`, so a `VM` nobody catches fails
where it resumes, as before. `partial` because a connection loop has no bound. -/
partial def runK (m : VM α) (kok : α → IO Unit) (kerr : IO.Error → IO Unit) : IO Unit :=
  match m with
  | .pure v => kok v
  | .recvE c kk => Io.recvRaw c 65536 (fun
    | .ok d    => runK (kk d) kok kerr
    | .error e => kerr e)
  | .sendE c bs kk => Io.sendRaw c bs (fun
    | .ok _    => runK kk kok kerr
    | .error e => kerr e)
  | .sendAllE c cs kk => Io.sendAllRaw c cs (fun
    | .ok _    => runK kk kok kerr
    | .error e => kerr e)
  | .recvTimeoutE c cl d kk => Io.recvTimeoutRaw c cl.schedule d 65536 (fun
    | none            => runK (kk none) kok kerr
    | some (.ok d)    => runK (kk (some d)) kok kerr
    | some (.error e) => kerr e)
  | .sleepE cl d kk => do
    let cancel ← Task.Cancel.new
    cl.schedule d cancel (runK kk kok kerr)
  | .closeE c kk => do
    if (← Io.closeRaw c) then
      runK kk kok kerr
    else
      kerr (.userError "Io.closeRaw: the loop refused a close submission")
  | .ioE act => act kok kerr
  | .throwE e => kerr e
  | .tryE b h => runK b kok (fun e => runK (h e) kok kerr)
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
  | .ioE act, f => .ioE (fun kok kerr => act (fun v => VM.runK (f v) kok kerr) kerr)
  | .throwE e, _ => .throwE e
  | .tryE b h, f => .tryE (VM.bind b f) (fun e => VM.bind (h e) f)
  | .empty, _ => .empty

instance : Monad VM where
  pure := .pure
  bind := VM.bind

/-- `IO` as a `VM` leaf, so a client's ordinary IO runs in the same machine. The leaf's own failure takes the
error continuation, exactly as a `throwE` does. -/
instance : MonadLift IO VM where monadLift act := .ioE (fun kok kerr => do try kok (← act) catch e => kerr e)

/-- Raise and catch, for the failure a connection answers rather than dies on. -/
instance : MonadExcept IO.Error VM where
  throw err := .throwE err
  tryCatch body handler := .tryE body handler

/-- **Attempt**: run `m`, turning a raise into an `Except` value — *wherever* the raise happens, before or
after a suspension: the interpreter carries the catch's stack in every effect's callback, so a handler that
reads a backend and then fails is caught exactly as one that fails at once. -/
def attempt (m : VM α) : VM (Except IO.Error α) := do
  try
    return .ok (← m)
  catch e => return .error e

/-- The effects, as the operations a client writes with `←`. -/
def recv (c : Conn) : VM (Option ByteArray) := .recvE c .pure
/-- **Read with a deadline**: `none` if `d` elapses first (the peer stalled), `some result` for the read. -/
def recvTimeout (c : Conn) (clock : Clock) (d : Std.Time.Millisecond.Offset) :
    VM (Option (Option ByteArray)) := .recvTimeoutE c clock d .pure
def send (c : Conn) (bs : ByteArray) : VM Unit := .sendE c bs (.pure ())
def sendAll (c : Conn) (chunks : Array ByteArray) : VM Unit := .sendAllE c chunks (.pure ())
def sleep (clock : Clock) (d : Std.Time.Millisecond.Offset) : VM Unit := .sleepE clock d (.pure ())
def close (c : Conn) : VM Unit := .closeE c (.pure ())


/-- **Run a connection loop** (fire-and-forget: the result is `Unit`; a raise nobody catches fails where the
machine resumes). -/
def run (m : VM Unit) : IO Unit := runK m (fun _ => (Pure.pure () : IO Unit)) (fun e => throw e)

/-- **Run a machine to a raw cell** (drive it, resolve the cell on completion; a raise nobody catches fails
where the machine resumes). -/
def runToCell (m : VM α) (cell : RawCell α) : IO Unit :=
  runK m (fun v => RawCell.resolve cell v) (fun e => throw e)

/-- **Spawn a machine and await its result** (run it to a fresh cell, park `resume` on it). This is the effect
an `asyncMachine` uses to await a sub-computation — a handler that itself suspends: `runToCell` starts the
machine (its effects resume on the loop thread) and `RawCell.await` parks the caller's continuation, which the
machine's final `resolve` fires. -/
def runAsync (m : VM α) (resume : α → IO Unit) : IO Unit :=
  match m with
  | .pure v => resume v      -- nothing to suspend on: no cell, no park
  | _ => do
    let cell ← RawCell.new
    runToCell m cell
    RawCell.await cell resume

end VM

end LeanIn.Runtime
