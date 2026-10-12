import Std

import LeanIn
import LeanIn.Runtime.Net
import LeanIn.Runtime.Http

/-!
# An HTTP server on `leanin`'s runtime

Run it with `lake exe server [port]` — the port defaults to 8080. It binds the loopback address, prints the
address it took, and serves every connection on an executor of our own, driving `Std.Http.Protocol.H1`'s pure
machine through `Runtime.Http.serveConn`. The protocol is reused (parsing, framing, keep-alive and the limits
stay in `H1` and its `Config`) and the driver, the accept loop and every await are ours, so a handler runs on one
of our carriers rather than on the stock `Task` pool.

`Runtime.serveUntilStopped` is the accept loop. It polls a non-blocking `tryAccept` between sleeps because the
interface has no selector yet, so a stop drains at one poll interval's latency rather than immediately; that
absence is recorded in the runtime's own docstring as W7's, not hidden here.
-/

open LeanIn

/-- The reply to any request: the method, path and version echoed back in a small body. -/
def reply (head : Std.Http.Request.Head) : Std.Http.Response.Head × ByteArray :=
  let body :=
    s!"hello from leanin\nmethod={head.method} path={head.uri} version={head.version}\n".toUTF8
  let headers :=
    Std.Http.Headers.empty.insert Std.Http.Header.Name.contentLength
      (Std.Http.Header.Value.ofString! (toString body.size))
  ({ status := .ok, version := .v11, headers }, body)

def main (args : List String) : IO UInt32 := do
  let port : UInt16 :=
    match args with
    | p :: _ => (p.toNat?.getD 8080).toUInt16
    | [] => 8080
  let hooks ← Runtime.Hooks.new
  let l ← Runtime.Listener.bind (Runtime.loopback port)
  let addr ← Runtime.Listener.sockName l
  let workers := 1
  let e ← Sched.Executor.new LeanIn.Task.Item 256 workers
  let bigstall := args.contains "bigstall"
  let cfg : Runtime.Http.Config :=
    { h1 := {}, clock := Runtime.Clock.live hooks,
      stallTimeout := if bigstall then 3600000 else 12000 }
  let quiet := args.contains "quiet"
  let handler : Runtime.Http.Handler := fun head => do
    if quiet then
      pure ()
    else
      let tid ← monadLift (IO.getTID : IO UInt64)
      monadLift (IO.println s!"  {head.method} {head.uri} -> 200, on carrier {tid}")
    return reply head
  IO.println s!"leanin server listening on {addr}"
  let prog : LeanIn.Task.EAsync IO.Error Unit :=
    Runtime.serveUntilStopped hooks e l 10 (Runtime.Http.serveConn hooks cfg · handler) []
  -- Driven by `Runtime.run`: the caller's thread runs the executor while it waits, which is what pumps the
  -- live clock's timer. The multi-carrier entry `Runtime.runCarriers` does **not** serve here — a connection is
  -- accepted by the kernel and never answered, because its caller waits on a cell without pumping and the accept
  -- loop's own sleep never resumes. That is a defect to fix rather than a configuration to choose, and it is
  -- recorded in the notes beside this file rather than worked around by leaving the server single-carrier blind.
  let outcome : Except IO.Error Unit ← Runtime.run e prog
  match outcome with
  | .ok _ => return 0
  | .error err =>
    IO.println s!"the accept loop ended: {err}"
    return 1
