import LeanIn
import LeanIn.Async

/-!
# A failed send's policy, bound and discarded

`lake exe asyncFailure <port>` accepts one connection, waits long enough for the peer's RST to arrive, and then
writes. The unbound machine must reach the same terminal as the bound one; binding may inspect the `Except`,
but it must not decide whether the continuation runs.
-/

open LeanIn

def payload : ByteArray := ByteArray.mk (Array.replicate 1048576 (UInt8.ofNat 120))

async unboundWrite (c : Runtime.Conn) (clock : Runtime.Clock)
    (onDone : Except IO.Error Unit → IO Unit) := do
  let slept : Unit := await (LeanIn.Runtime.Io.sleepRaw clock.schedule (200 : Std.Time.Millisecond.Offset))
  await (LeanIn.Runtime.Io.sendRaw c payload)
  onDone (.ok ())
  halt

async boundWrite (c : Runtime.Conn) (clock : Runtime.Clock)
    (onDone : Except IO.Error Unit → IO Unit) := do
  let slept : Unit := await (LeanIn.Runtime.Io.sleepRaw clock.schedule (200 : Std.Time.Millisecond.Offset))
  let r := await (LeanIn.Runtime.Io.sendRaw c payload)
  onDone r
  halt

def main (args : List String) : IO UInt32 := do
  let port : UInt16 := ((args.headD "8799").toNat?.getD 8799).toUInt16
  let hooks ← Runtime.Hooks.new
  let clock := Runtime.Clock.live hooks
  let l ← Runtime.Listener.bind (Runtime.loopback port)
  let e ← Sched.Executor.new LeanIn.Task.Item 256 1
  let accepted : LeanIn.Task.EAsync IO.Error Runtime.Conn := Runtime.Listener.accept l hooks
  let c ← match ← Runtime.run e accepted with
    | .ok c => pure c
    | .error e => IO.eprintln s!"asyncFailure: accept: {e}"; return 1
  let unbound : LeanIn.Task.EAsync IO.Error Unit :=
    ⟨fun k ctx => unboundWrite.run c clock (fun r => k r ctx)⟩
  let bound : LeanIn.Task.EAsync IO.Error Unit :=
    ⟨fun k ctx => boundWrite.run c clock (fun r => k r ctx)⟩
  let ru ← Runtime.run e unbound
  let rb ← Runtime.run e bound
  Runtime.Io.stop
  match ru, rb with
  | .ok (), .error _ => IO.println "asyncFailure: unbound reached its terminal; bound observed the failure"; return 0
  | .ok (), .ok () => IO.println "asyncFailure: unbound reached its terminal; bound's write succeeded"; return 0
  | .error e, _ => IO.eprintln s!"asyncFailure: unbound ended in an error: {e}"; return 1
