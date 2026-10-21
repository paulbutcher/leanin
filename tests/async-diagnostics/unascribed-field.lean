import LeanIn
import LeanIn.Async
open LeanIn

-- A pure-bound variable with no ascription, live across a suspension, in a shape the compiler cannot infer:
-- it must be rejected with the variable named.
async def trapUnascribed (c : LeanIn.Runtime.Conn) : Unit := do
  let mystery := ByteArray.empty
  let bs := await (LeanIn.Runtime.Io.recvRaw c 65536)
  let bs2 := mystery ++ bs
  await (LeanIn.Runtime.Io.sendAllRaw c #[bs2])
  recurse
