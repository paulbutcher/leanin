import LeanIn
import LeanIn.Async

/-!
# A compiled hello-world server

`lake exe hello [port]` binds the loopback port, serves every connection with a compiled accept loop, and
answers each request with one fixed HTTP response through a compiled per-connection machine. The three
machines are the guide's shape — a handler, a spawn per connection, and an accept loop that recurses — over
the runtime's own primitives: no `Std.Http.Server` and no stock `Task` in the serving path.

Every suspension is one of the classified effects: the accept parks on the listener's cell, the read and the
write park on the connection, and the spawn schedules the connection machine as an executor item through the
same inject that wakes the driver.
-/

open LeanIn

/-- The one response: a five-byte body, with the connection closed after it. -/
def helloResponse : ByteArray :=
  "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 5\r\n\r\nhello".toUTF8

-- One connection's work: read the request, answer, close, and report the close. The write is deliberately
-- unbound: the compiler's policy for an unbound send is to close the connection when it fails, which is this
-- example's boundary handling — a failed write ends that connection and reaches no other connection.
asyncMachine helloConn (c : LeanIn.Runtime.Conn) (onDone : Except IO.Error Unit → IO Unit) := do
  let req := await (LeanIn.Runtime.Io.recvRaw c 65536)
  await (LeanIn.Runtime.Io.sendAllRaw c #[helloResponse])
  let closed := await (LeanIn.Runtime.Io.closeRaw c)
  onDone (if closed then .ok () else .error (IO.userError "helloConn: the loop refused the close"))

-- The accept loop: one connection at a time, its handler spawned as an executor item, then recurse. The
-- listener and the inject are the loop's carried state; an accept failure ends the loop loudly.
asyncMachine helloServe (l : LeanIn.Runtime.Listener) (push : LeanIn.Task.Item → BaseIO Unit)
    (onDone : Except IO.Error Unit → IO Unit) := do
  let c : Except IO.Error LeanIn.Runtime.Conn := await (LeanIn.Runtime.Io.acceptRaw l push)
  match c with
  | .error e =>
    onDone (.error e)
    halt
  | .ok conn =>
    -- Handlers are unsupervised here: the handle is discarded deliberately. A connection's failure is
    -- confined to that connection by the handler's own policy, and the loop's only terminal is an accept the
    -- listener can no longer complete — which is what reaches the run's continuation and `main`.
    await (helloConn.spawn push conn)
    recurse

def main (args : List String) : IO UInt32 := do
  let port := (args.head?.bind (·.toNat?)).getD 8085
  let l ← LeanIn.Runtime.Listener.bind (LeanIn.Runtime.loopback port.toUInt16)
  let e ← LeanIn.Sched.Executor.new LeanIn.Task.Item 256 1
  let push := LeanIn.Runtime.sharedPush e
  let addr ← LeanIn.Runtime.Listener.sockName l
  IO.println s!"hello listening on {addr}"
  (← IO.getStdout).flush
  -- The compiled loop owns the connection; only its terminal — an accept the loop can no longer complete —
  -- reaches the wrapper's continuation, which is what lets `main` report it.
  let prog : LeanIn.Task.EAsync IO.Error Unit :=
    ⟨fun k ctx => helloServe.run l push (fun r => k r ctx)⟩
  match (← (LeanIn.Runtime.run e prog : IO (Except IO.Error Unit))) with
  | .ok () => return 0
  | .error e =>
    IO.eprintln s!"hello: {e}"
    return 1
