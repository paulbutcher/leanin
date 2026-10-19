import LeanIn
import LeanIn.Async
open LeanIn

-- A bound write result ascribed to Nat and never used afterwards: the ascription is on the binder, so it fails
-- even though the value is dead. (`Except IO.Error Unit` is what the write delivers.)
asyncMachine deadBadSend (c : LeanIn.Runtime.Conn) := do
  await (LeanIn.Runtime.Io.sendAllRaw c #[ByteArray.empty])
  let x : Nat := await (LeanIn.Runtime.Io.sendAllRaw c #[ByteArray.empty])
  await (LeanIn.Runtime.Io.closeRaw c)
