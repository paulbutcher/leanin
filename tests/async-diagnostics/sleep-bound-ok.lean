import LeanIn
import LeanIn.Async
open LeanIn

-- A bound sleep result that crosses a suspension: the continuation binds the name to `()`, so a `Unit`
-- ascription elaborates and the state carries it.
async def boundSleep (c : LeanIn.Runtime.Conn) (clock : LeanIn.Runtime.Clock) : Unit := do
  let u : Unit := await (LeanIn.Runtime.Io.sleepRaw clock.schedule 1)
  let bs := await (LeanIn.Runtime.Io.recvRaw c 65536)
  let _seen := u
  await (LeanIn.Runtime.Io.sendAllRaw c #[bs])
  recurse
