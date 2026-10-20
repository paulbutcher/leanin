import LeanIn
import LeanIn.Async
open LeanIn

-- A sleep result ascribed to Nat and never used afterwards: the ascription is on the binder itself, so this
-- fails at elaboration even though no state field would ever carry it.
async deadBadSleep (c : LeanIn.Runtime.Conn) (clock : LeanIn.Runtime.Clock) := do
  let u : Nat := await (LeanIn.Runtime.Io.sleepRaw clock.schedule 1)
  await (LeanIn.Runtime.Io.closeRaw c)
