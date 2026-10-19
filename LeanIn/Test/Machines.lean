import LeanIn
import LeanIn.Async
import LeanIn.Runtime.Net

/-!
# Scenario machines for the time-as-effect controls

`amDelayed` and `amStall` are the compiled machines SC24 serves: one sleeps `d` on the injected clock between
read and answer (`sleepRaw`), the other races a read against the same stated instant (`recvTimeoutRaw`). Each
reports its close *submission* on `onDone` — the connection's closure is observed separately, by the client
reading to EOF — so a harness can hold the run until the machine's terminal step rather than its first
suspension.
-/

open LeanIn

-- Read a request, sleep `d` on the injected clock, answer, close, and report the close.
asyncMachine amDelayed (c : LeanIn.Runtime.Conn) (clock : LeanIn.Runtime.Clock) (d : Std.Time.Millisecond.Offset)
    (onDone : Except IO.Error Unit → IO Unit) := do
  let bs := await (LeanIn.Runtime.Io.recvRaw c 65536)
  await (LeanIn.Runtime.Io.sleepRaw clock.schedule d)
  await (LeanIn.Runtime.Io.sendAllRaw c #[bs])
  let closed := await (LeanIn.Runtime.Io.closeRaw c)
  onDone (if closed then .ok () else .error (IO.userError "amDelayed: the loop refused the close"))

-- Race a read against the stated instant: answer an arrived request, close with nothing written on the
-- deadline or on end of stream, and report the close (the transport error is reported too).
asyncMachine amStall (c : LeanIn.Runtime.Conn) (clock : LeanIn.Runtime.Clock) (d : Std.Time.Millisecond.Offset)
    (onDone : Except IO.Error Unit → IO Unit) := do
  let rt := await (LeanIn.Runtime.Io.recvTimeoutRaw c clock.schedule d 65536)
  match rt with
  | none =>
    let closed := await (LeanIn.Runtime.Io.closeRaw c)
    onDone (if closed then .ok () else .error (IO.userError "amStall: the loop refused the close"))
  | some (.ok (some bs)) =>
    await (LeanIn.Runtime.Io.sendAllRaw c #[bs])
    let closed := await (LeanIn.Runtime.Io.closeRaw c)
    onDone (if closed then .ok () else .error (IO.userError "amStall: the loop refused the close"))
  | some (.ok none) =>
    let closed := await (LeanIn.Runtime.Io.closeRaw c)
    onDone (if closed then .ok () else .error (IO.userError "amStall: the loop refused the close"))
  | some (.error e) =>
    let closed := await (LeanIn.Runtime.Io.closeRaw c)
    onDone (if closed then .error e else .error (IO.userError s!"{e}; and the loop refused the close"))
