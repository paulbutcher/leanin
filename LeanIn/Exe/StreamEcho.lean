import Std

import LeanIn
import LeanIn.Runtime.Net
import LeanIn.Examples.Http.Server

/-!
# A streaming HTTP echo on `leanin`'s runtime

Run it with `lake exe streamEcho [port]`. Unlike `server`, the handler reads the request body and writes the
response body incrementally: neither direction is accumulated, and the response is `Transfer-Encoding: chunked`
on HTTP/1.1. A `POST` echoes each body chunk as it arrives; any other method answers one fixed chunk.
-/

open LeanIn
open LeanIn.Examples.Http

namespace LeanIn.Exe.StreamEcho

/-- Echo the request body chunk by chunk, then terminate the chunked response. -/
partial def echoBody (body : Server.BodyReader) (w : Server.ResponseWriter) : Runtime.VM Unit := do
  match ← body.recv 65536 with
  | some chunk =>
    w.write chunk
    echoBody body w
  | none => w.finish

/-- `POST` streams; everything else answers one chunk. The head is sent before any body is read. -/
def handler : Server.StreamHandler := fun head body w => do
  w.start { status := 200, reason := "OK" }
  if head.method == H1.Method.post then
    echoBody body w
  else
    w.write "hello\n".toUTF8
    w.finish

end LeanIn.Exe.StreamEcho

open LeanIn.Exe.StreamEcho

def main (args : List String) : IO UInt32 := do
  let port : UInt16 :=
    match args with
    | p :: _ => (p.toNat?.getD 8790).toUInt16
    | [] => 8790
  let hooks ← Runtime.Hooks.new
  let l ← Runtime.Listener.bind (Runtime.loopback port)
  let addr ← Runtime.Listener.sockName l
  let e ← Sched.Executor.new LeanIn.Task.Item 256 1
  let cfg : Server.Config := { clock := Runtime.Clock.live hooks }
  IO.println s!"leanin stream server listening on {addr}"
  let prog : LeanIn.Task.EAsync IO.Error Unit :=
    Runtime.serveForever hooks l (Server.serveConnStream cfg · handler)
  let outcome : Except IO.Error Unit ← Runtime.run e prog
  Runtime.Io.stop
  match outcome with
  | .ok _ => return 0
  | .error err =>
    IO.println s!"the accept loop ended: {err}"
    return 1
