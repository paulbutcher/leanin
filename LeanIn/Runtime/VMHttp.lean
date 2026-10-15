import Std.Http.Protocol.H1
import Std.Http.Data
import LeanIn.Runtime.Net
import LeanIn.Runtime.Io
import LeanIn.Runtime.VM

/-!
# The HTTP/1.1 connection driver, in the `VM` monad (experiment)

`Runtime.Http.serveConn`'s connection loop rewritten in the defunctionalizing `VM`: the H1 machine stepping,
event processing and branching stay **pure**; only the socket operations (`VM.recv`/`VM.sendAll`/`VM.close`)
are effects, resumed by raw delivery. This is the delivery VM applied to the real benchmark path, the first
client of the general engine — single-carrier, `VM` as the public face.

The stall deadline is **not** carried here yet (the benchmark's reads complete long before it would fire);
`recvTimeout` is the roadmap item that adds it back comparably to `serveConn`.
-/

namespace LeanIn.Runtime.VMHttp

/-- A request handler for the VM driver: pure (the benchmark's `reply`/`static` are). A suspending handler is
the `spawn`/task-effect item. -/
abbrev PureHandler := Std.Http.Request.Head → Std.Http.Response.Head × ByteArray

/-- **Run the handler on `endHeaders` events**, folding the machine forward. Pure: the machine's own `send`/
`sendData`/`userClosedBody` queue the response, exactly as `serveConn`'s `drive` does. A handler that should
fail is answered `closeWithError`, matching `serveConn`. -/
def processEvents (machine : Std.Http.Protocol.H1.Machine .receiving)
    (events : Array (Std.Http.Protocol.H1.Event .receiving)) (handler : PureHandler) :
    Std.Http.Protocol.H1.Machine .receiving :=
  events.foldl (fun m e => match e with
    | .endHeaders head =>
      let (respHead, body) := handler head
      m.send respHead |>.sendData #[Std.Http.Chunk.ofByteArray body] |>.userClosedBody
    | _ => m) machine

/-- Whether the step made progress — it wrote bytes, or produced an event other than `needMoreData` (which the
machine re-emits on every starved step). Mirrors `drive`'s gate. -/
def madeProgress (outputSize : Nat) (events : Array (Std.Http.Protocol.H1.Event .receiving)) : Bool :=
  outputSize > 0 || events.any (fun e => match e with | .needMoreData _ => false | _ => true)

/-- **The read → step → dispatch → write cycle, in `VM`.** -/
partial def vmDrive (c : Conn) (handler : PureHandler)
    (machine : Std.Http.Protocol.H1.Machine .receiving) : VM Unit := do
  let (machine', step) := machine.step
  if step.output.size > 0 then
    VM.sendAll c step.output.data
  let machine'' := processEvents machine' step.events handler
  if machine''.halted then
    pure ()
  else if madeProgress step.output.size step.events then
    vmDrive c handler machine''
  else
    match ← VM.recv c with
    | none    => vmDrive c handler machine''.noMoreInput
    | some bs => vmDrive c handler (machine''.feed bs)

/-- **Serve one connection in `VM`**: drive from a fresh machine, then close the write side. -/
def vmServeConn (c : Conn) (h1 : Std.Http.Protocol.H1.Config) (handler : PureHandler) : VM Unit := do
  vmDrive c handler ({ config := h1 } : Std.Http.Protocol.H1.Machine .receiving)
  VM.close c

end LeanIn.Runtime.VMHttp
