import Std.Http.Protocol.H1
import Std.Http.Data
import LeanIn.Runtime.Net
import LeanIn.Runtime.Leaf
import LeanIn.Task.Error

/-!
# The HTTP/1.1 connection driver, on our carriers

`Std.Http.Protocol.H1` is the protocol: a pure state machine that reads request bytes and writes response
bytes, plus the parser, the framer and the encoder behind it. What it does not have is a connection loop that
runs on our carriers — `Std.Http.Server`'s own loop runs as a stock `Task`, and it dispatches the handler with
`.asTask` (`Std/Http/Server/Connection.lean:319`), which is the finding W2 recorded and W9 answers.

This module is that per-connection driver and nothing else. The protocol is reached through its own
`Machine`: `feed` takes the socket's bytes in, `step` advances and yields output and events, `send`/`sendData`
queue the response, and `pullBody`/`takeEvents`/`takeOutput`/`halted`/`closeReader`/`noMoreInput` are the
machine's own readings and transitions. Nothing here scans bytes; there is no parser and no framer. Neither is
there an accept loop: `LeanIn.Runtime.Net`'s `serveNJoin` is the accept loop, and this driver is its per-connection body.

Every socket operation comes back as a value rather than a panic (`LeanIn/Runtime/Net.lean`), so a peer that
goes away mid-request ends the connection as an `error` rather than as a process.
-/

namespace LeanIn.Runtime.Http

/-- A request handler of ours: the parsed request head to the response head and its fully-buffered body, in
our task monad. A plain function rather than the shipped `Handler` class: the class's other members are
streaming and 100-continue concerns this driver does not carry yet, while the call shape — dispatch on the
parsed request head, return the response — is the same. -/
abbrev Handler := Std.Http.Request.Head → Task.EAsync IO.Error (Std.Http.Response.Head × ByteArray)

/-- **The read → feed → step → dispatch → write cycle for one connection.**

`machine.step` advances the protocol and yields the bytes it wants written and the events it produced; the
output goes out verbatim, an `endHeaders` event is the one place the handler runs, and the remaining events
either end the reading (`close`/`failed`/`closeBody`) or say nothing this driver acts on. The loop ends on
`machine.halted`, which `Connection: close` reaches once the response is flushed; while the writer is idle
(`.pending`, no response begun) the machine is waiting for request bytes and the loop reads them, and
otherwise it keeps stepping so pending output is flushed before it ever blocks on the socket.

`partial` because a connection has no bound, and `Async` is `Inhabited`; the recursion is the loop. -/
private partial def drive (hooks : Hooks) (c : Conn) (handler : Handler)
    (machine : Std.Http.Protocol.H1.Machine .receiving) : Task.EAsync IO.Error Unit := do
  let (machine, step) := machine.step
  if step.output.size > 0 then
    Conn.sendAll c hooks step.output.data
  let mut machine := machine
  for event in step.events do
    match event with
    | .endHeaders head =>
      let (respHead, body) ← handler head
      machine := machine.send respHead
        |>.sendData #[Std.Http.Chunk.ofByteArray body]
        |>.userClosedBody
    | .close     => machine := machine.closeReader
    | .failed _  => machine := machine.closeReader
    | .closeBody => machine := machine.closeReader
    | _ => pure ()
  if machine.halted then
    pure ()
  else if machine.writer.state == .pending then
    match ← Conn.recv c hooks with
    | some bytes => drive hooks c handler (machine.feed bytes)
    | none       => drive hooks c handler (machine.noMoreInput)
  else
    drive hooks c handler machine

/-- **Serve one connection**: run `drive` from a fresh machine built from `config` alone, then shut the write
side down so the peer reads the response to end of stream.

The machine is built as `{ config := config }`: `agentName` keeps its `none` default and `instant` is left
`none`, so no `Server` and no `Date` header can enter the encoder and the response is a function of the request
and the handler's head. `Std.Http.Server.Config` and every `Std.Http.Server` type stay off this path, as does
any `Std.Http.Transport` instance — `Transport` is typed over `Async`, which would hand the driver a stock-typed
socket and put the work back on the pool. -/
def serveConn (hooks : Hooks) (config : Std.Http.Protocol.H1.Config) (c : Conn)
    (handler : Handler) : Task.EAsync IO.Error Unit := do
  drive hooks c handler ({ config := config } : Std.Http.Protocol.H1.Machine .receiving)
  Conn.shutdown c hooks

end LeanIn.Runtime.Http
