import LeanIn
import LeanIn.Async
open LeanIn

-- A sleep result ascribed to something other than Unit, live across a suspension: a loud elaboration
-- mismatch, never a silently mistyped state field.
async def badSleep (c : LeanIn.Runtime.Conn) (clock : LeanIn.Runtime.Clock) : Unit := do
  let u : Nat := await (LeanIn.Runtime.Io.sleepRaw clock.schedule 1)
  let bs := await (LeanIn.Runtime.Io.recvRaw c 65536)
  let _seen := u
  await (LeanIn.Runtime.Io.sendAllRaw c #[bs])
  recurse
