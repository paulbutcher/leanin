import LeanIn
import LeanIn.Async
import LeanIn.Runtime.Net
open LeanIn

-- The formerly trapping shape: a parameter the body uses but never rebinds. Thread-by-default carries it
-- across `recurse` — this must ELABORATE (it was silently a constant before, which is how the driver's
-- protocol machine was once discarded).
async def carried (c : LeanIn.Runtime.Conn) (tag : ByteArray) : Unit := do
  let bs := await (LeanIn.Runtime.Io.recvRaw c 65536)
  await (LeanIn.Runtime.Io.sendAllRaw c #[tag, bs])
  recurse

-- The representation the carry claim makes: `tag` is a field of the states, not a step parameter — `step`
-- takes the connection alone, while `run` keeps the full parameter list. If `tag` ever becomes a constant
-- step parameter again, `step`'s type gains it and the first example stops elaborating.
example : LeanIn.Runtime.Conn → carried.St → IO Unit := carried.step
example : LeanIn.Runtime.Conn → ByteArray → LeanIn.Async.Completion Unit → IO Unit := carried.run
