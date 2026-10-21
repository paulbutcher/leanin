import LeanIn

/-!
`lake exe drainDeadline` starts a polling accept loop with a 100 ms drain deadline, connects a client,
and blocks its handler in a scoped 60 s sleep. Stopping the executor must abort the handler at the
deadline and return from the loop within a bounded time.
-/

open LeanIn

def main : IO UInt32 := do
  let hooks ← Runtime.Hooks.new
  let clock := Runtime.Clock.live hooks
  let e ← Sched.Executor.new LeanIn.Task.Item 256 1
  let l ← Runtime.Listener.bind (Runtime.loopback 0)
  let started ← (IO.Promise.new : IO (IO.Promise (Except IO.Error Unit)))
  let body (_ : Runtime.Conn) : LeanIn.Task.EAsync IO.Error Unit :=
    ⟨fun k ctx => do
      IO.Promise.resolve (Except.ok ()) started
      Runtime.VM.runAsync (Runtime.VM.requestScope (Runtime.VM.sleep clock 60000))
        (fun _ => k (.ok ()) ctx)⟩
  let serverProg : LeanIn.Task.EAsync IO.Error Unit :=
    Runtime.serveUntilStoppedWithDeadline hooks e l 1 100 body []
  let serverTask ← IO.asTask (Runtime.run e serverProg) _root_.Task.Priority.dedicated
  let addr ← Runtime.Listener.sockName l
  let client ← Std.Async.Async.block do
    let c ← Std.Async.TCP.Socket.Client.mk
    c.connect addr
    return c
  let started? ← IO.wait (IO.Promise.result? started)
  if started?.isNone then
    IO.eprintln "drainDeadline: handler never started"
    return 1
  let t0 ← IO.monoNanosNow
  e.stop
  let outer : Except IO.Error (Except IO.Error Unit) ← IO.wait serverTask
  let elapsedMs := ((← IO.monoNanosNow) - t0) / 1000000
  let _ := client
  match outer with
  | Except.error e => IO.eprintln s!"drainDeadline: driver failed: {e}"; return 1
  | Except.ok (.error e) => IO.eprintln s!"drainDeadline: loop failed: {e}"; return 1
  | Except.ok (.ok ()) =>
    IO.println s!"drainDeadline|returned=yes|elapsedMs={elapsedMs}"
    if elapsedMs < 2000 then return 0 else return 1
