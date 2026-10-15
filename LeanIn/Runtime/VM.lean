import LeanIn.Runtime.Net
import LeanIn.Runtime.Io
import LeanIn.Runtime.Clock

/-!
# A defunctionalizing task monad (experiment)

`VM` is a free machine over the engine's effects — reactor (`recv`/`send`/`sendAll`/`close`), timers
(`recvTimeout`), and **tasks** (`spawn`/`await`/`race`). A client writes ordinary `do`; the incremental
interpreter drives it by **raw resume**: socket completions on the loop thread, task completions through a raw
cell, never a `Join`/`Item`/inject.

`spawn`/`await`/`race` make it a concurrency engine rather than a socket driver. On a single carrier they are
*cooperative*: a spawned machine's effects resume on the same loop thread as the parent's, and its completion
resolves a raw cell the awaiter is parked on — no second carrier, no parallelism, the single-carrier design.

**The same-type shape.** `spawn`/`await`/`race` are uniform at `α` — the spawned machine, its cell, and the
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
  | empty

namespace VM

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
  | .empty, _ => .empty

instance : Monad VM where
  pure := .pure
  bind := VM.bind

/-- The effects, as the operations a client writes with `←`. -/
def recv (c : Conn) : VM (Option ByteArray) := .recvE c .pure
/-- **Read with a deadline**: `none` if `d` elapses first (the peer stalled), `some result` for the read. -/
def recvTimeout (c : Conn) (clock : Clock) (d : Std.Time.Millisecond.Offset) :
    VM (Option (Option ByteArray)) := .recvTimeoutE c clock d .pure
def send (c : Conn) (bs : ByteArray) : VM Unit := .sendE c bs (.pure ())
def sendAll (c : Conn) (chunks : Array ByteArray) : VM Unit := .sendAllE c chunks (.pure ())
def sleep (clock : Clock) (d : Std.Time.Millisecond.Offset) : VM Unit := .sleepE clock d (.pure ())
def close (c : Conn) : VM Unit := .closeE c (.pure ())

/-- **The incremental interpreter**, in continuation-passing form. `partial` because a connection loop has no
bound. -/
partial def runK : VM α → (α → IO Unit) → IO Unit
  | .pure v, k      => k v
  | .recvE c kk, k   => Io.recvRaw c 65536 (fun r => runK (kk r) k)
  | .sendE c bs kk, k => Io.sendRaw c bs (runK kk k)
  | .sendAllE c cs kk, k => Io.sendAllRaw c cs (runK kk k)
  | .recvTimeoutE c cl d kk, k => Io.recvTimeoutRaw c cl.schedule d 65536 (fun r => runK (kk r) k)
  | .sleepE cl d kk, k => do
    let cancel ← Task.Cancel.new
    cl.schedule d cancel (runK kk k)
  | .closeE c kk, k  => do Io.closeRaw c; runK kk k
  | .empty, _        => (Pure.pure () : IO Unit)

/-- **Run a connection loop** (fire-and-forget: the result is `Unit`). -/
def run (m : VM Unit) : IO Unit := runK m (fun _ => (Pure.pure () : IO Unit))

/-- **Run a machine to a raw cell** (drive it, resolve the cell on completion). -/
def runToCell (m : VM α) (cell : RawCell α) : IO Unit := runK m (fun v => RawCell.resolve cell v)

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
