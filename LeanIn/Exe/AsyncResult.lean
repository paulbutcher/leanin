import LeanIn
import LeanIn.Async

/-!
# A result-bearing compiled machine

`lake exe asyncResult` runs two `async def` declarations: one returns immediately, one returns after a timer.
The public call returns `Task.EAsync IO.Error Nat`; `return` supplies the completion the compiler owns.
-/

open LeanIn

async def immediate (u : Unit) : Nat := do
  let unused := u
  return 42

async def afterTimer (u : Unit) (clock : Runtime.Clock) : Nat := do
  let unused := u
  let slept : Unit := await (LeanIn.Runtime.Io.sleepRaw clock.schedule (5 : Std.Time.Millisecond.Offset))
  return 43

def main : IO UInt32 := do
  let hooks ← Runtime.Hooks.new
  let clock := Runtime.Clock.live hooks
  let e ← Sched.Executor.new LeanIn.Task.Item 256 1
  let a ← Runtime.run e (immediate ())
  let b ← Runtime.run e (afterTimer () clock)
  Runtime.Io.stop
  match a, b with
  | .ok 42, .ok 43 =>
    IO.println "async-result: immediate and post-suspension returns delivered"
    return 0
  | _, _ =>
    IO.eprintln "async-result: the returns did not deliver the expected values"
    return 1
