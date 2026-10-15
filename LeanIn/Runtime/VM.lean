import LeanIn.Runtime.Net
import LeanIn.Runtime.Io
import LeanIn.Runtime.Clock

/-!
# A defunctionalizing task monad (experiment)

`VM` is a free machine over the socket effects. A client writes ordinary `do` — it elaborates through the
`Monad` instance into this data representation — and the incremental interpreter drives it by **raw loop-thread
resume**: each effect's continuation runs *directly* in the completion, with no `Join` cell, `Item`, inject or
carrier fire. A client's own `←` continuations become machine data delivered directly, rather than being
re-wrapped through the generic completion path every suspension. It is the client-side half of the
defunctionalization the raw echo measured: the client writes `do`, the engine resumes a machine.

The representation is a GADT with an explicit `then` node: `Monad.bind` is a constructor (O(1), structural),
and the interpreter carries its own continuation (`runK`) to thread values through it. The effects are the
socket operations; `sleep`/`spawn`/`select` are the later items that make it a concurrency engine rather than an
echo.
-/

namespace LeanIn.Runtime

/-- A defunctionalized computation. `pure`/`then` are the monad; `recv`/`send`/`close` are the effect nodes,
whose continuation is the *next machine*, not a CPS closure re-wrapped per bind. -/
inductive VM (α : Type) where
  | pure (v : α)
  | recvE (c : Conn) (k : Option ByteArray → VM α)
  | recvTimeoutE (c : Conn) (clock : Clock) (d : Std.Time.Millisecond.Offset)
      (k : Option (Option ByteArray) → VM α)
  | sendE (c : Conn) (bs : ByteArray) (k : VM α)
  | sendAllE (c : Conn) (chunks : Array ByteArray) (k : VM α)
  | closeE (c : Conn) (k : VM α)
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
def close (c : Conn) : VM Unit := .closeE c (.pure ())

/-- **The incremental interpreter**, in continuation-passing form so `then` threads its value. Each effect
resumes by a raw loop-thread completion — the continuation runs *in* the completion, so a client's next step is
delivered directly rather than scheduled through a cell and an item. `partial` because a connection loop has no
bound: the recursion rides the lazy machine the client builds. -/
partial def runK : VM α → (α → IO Unit) → IO Unit
  | .pure v, k      => k v
  | .recvE c kk, k   => Io.recvRaw c 65536 (fun r => runK (kk r) k)
  | .recvTimeoutE c cl d kk, k => Io.recvTimeoutRaw c cl.schedule d 65536 (fun r => runK (kk r) k)
  | .sendE c bs kk, k => Io.sendRaw c bs (runK kk k)
  | .sendAllE c cs kk, k => Io.sendAllRaw c cs (runK kk k)
  | .closeE c kk, k  => do Io.closeRaw c; runK kk k
  | .empty, _        => (Pure.pure () : IO Unit)

/-- **Run a connection loop** (fire-and-forget: the result is `Unit`). -/
def run (m : VM Unit) : IO Unit := runK m (fun _ => (Pure.pure () : IO Unit))

end VM

end LeanIn.Runtime
