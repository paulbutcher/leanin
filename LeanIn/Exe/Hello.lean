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

/-- The keep-alive response the benchmark arm serves: the same body, the connection left open so the client
sends its next request on it (the shape `bench/load.mjs` drives). -/
def helloKeepResponse : ByteArray :=
  "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".toUTF8

-- One connection's work: read the request, answer, close, and report the close. The write is deliberately
-- unbound: its `Except` is discarded, and a failed write's connection is closed by the loop, so the following
-- close sees the failure at that operation; no other connection is affected.
async def helloConn (c : LeanIn.Runtime.Conn) : Unit := do
  let req := await (LeanIn.Runtime.Io.recvRaw c 65536)
  await (LeanIn.Runtime.Io.sendAllRaw c #[helloResponse])
  let closed := await (LeanIn.Runtime.Io.closeRaw c)
  if closed then return () else throw (IO.userError "helloConn: the loop refused the close")

-- A keep-alive connection loop, for the benchmark arm: request, answer, request again on the same connection.
async def helloKeep (c : LeanIn.Runtime.Conn) : Unit := do
  let req := await (LeanIn.Runtime.Io.recvRaw c 65536)
  await (LeanIn.Runtime.Io.sendAllRaw c #[helloKeepResponse])
  recurse

-- The accept loop: one connection at a time, its handler spawned as an executor item, then recurse. The
-- listener, the inject and the mode are the loop's carried state; an accept failure ends the loop loudly.
async def helloServe (l : LeanIn.Runtime.Listener) (push : LeanIn.Task.Item → BaseIO Unit)
    (keep : Bool) : Unit := do
  let c : Except IO.Error LeanIn.Runtime.Conn := await (LeanIn.Runtime.Io.acceptRaw l push)
  match c with
  | .error e =>
    throw e
  | .ok conn =>
    -- Handlers are unsupervised here: the handle is discarded deliberately. A connection's failure is
    -- confined to that connection by the handler's own policy, and the loop's only terminal is an accept the
    -- listener can no longer complete — which is what reaches the run's continuation and `main`.
    if keep then
      await (helloKeep.spawn push conn)
      recurse
    else
      await (helloConn.spawn push conn)
      recurse

def main (args : List String) : IO UInt32 := do
  let port := (args.head?.bind (·.toNat?)).getD 8085
  let keep := args.getD 1 "close" == "keep"
  let l ← LeanIn.Runtime.Listener.bind (LeanIn.Runtime.loopback port.toUInt16)
  let e ← LeanIn.Sched.Executor.new LeanIn.Task.Item 256 1
  let push := LeanIn.Runtime.sharedPush e
  let addr ← LeanIn.Runtime.Listener.sockName l
  IO.println s!"hello listening on {addr}"
  (← IO.getStdout).flush
  -- The compiled loop owns the connection; only its terminal — an accept the loop can no longer complete —
  -- reaches the wrapper's continuation, which is what lets `main` report it.
  match (← (LeanIn.Runtime.run e (helloServe l push keep) : IO (Except IO.Error Unit))) with
  | .ok () => return 0
  | .error e =>
    IO.eprintln s!"hello: {e}"
    return 1
