import LeanIn
import LeanIn.Async
open LeanIn

-- A destructuring let: rejected with the construct named and the remedy stated.
async def trapDestructuring (c : LeanIn.Runtime.Conn) : Unit := do
  let bs := await (LeanIn.Runtime.Io.recvRaw c 65536)
  let (a, b) := (bs, bs)
  await (LeanIn.Runtime.Io.sendAllRaw c #[a, b])
  recurse
