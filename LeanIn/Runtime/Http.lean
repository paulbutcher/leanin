import Std.Http.Data
import LeanIn.Http.H1
import LeanIn.Runtime.Net
import LeanIn.Runtime.Leaf
import LeanIn.Runtime.Time
import LeanIn.Task.Error

/-!
# The HTTP/1.1 service driver, on our carriers

`Std.Http.Protocol.H1` is the protocol: a pure state machine that reads request bytes and writes response
bytes, plus the parser, the framer and the encoder behind it. What it does not have is a connection loop that
runs on our carriers — `Std.Http.Server`'s own loop runs as a stock `Task`, and it dispatches the handler with
`.asTask` (`Std/Http/Server/Connection.lean:319`), which is the finding W2 recorded and W9 answers.

This module is that per-connection driver and nothing else. The protocol is reached through its own `Machine`:
`feed` takes the socket's bytes in, `step` advances and yields output and events, `send`/`sendData` queue the
response, `closeWithError` puts a failure response on the wire, and `halted`/`noMoreInput`/`writer.state` are
the machine's own readings. Nothing here scans bytes; there is no parser and no framer. Neither is there an
accept loop: `LeanIn.Runtime.Net`'s `serveNJoin` is the accept loop, and this driver is its per-connection body.

**One connection serves as many exchanges as the peer asks for.** Keep-alive is the machine's own
`resetForNextMessage`, which is `private` (`Std/Http/Protocol/H1.lean:593`) and so cannot be *called* into
being: what the driver does is stop suppressing it. Its caller is `processWrite`'s `.complete` branch, under the
reader `.complete`, the writer `.complete` and `keepAlive`, and it resets the reader to `.needStartLine`, the
writer to `.pending`, and preserves `input` — which is why the loop's gate reads as its default branch and steps
again only behind something observable. The dispositions that mapped `close`/`failed`/`closeBody` to
`closeReader` are gone: each means "this message's body is done" — `closeBody` is emitted for every body-less
request's completed body, which is this driver's ordinary `GET` — while `closeReader` sets `noMoreInput`, which
the machine consults only where it closes a reader at `noMoreInput ∧ input.atEnd`. Mapping them wrote an EOF the
peer never sent.

**What the deadline bounds, and what it does not.** `Config.stallTimeout` wraps each `Conn.recv` in
`Runtime.withTimeout` against the injected `Clock`, so the interval between asking the socket for bytes and
bytes-or-EOF arriving is bounded — one bound covering a connection that sends nothing at all, one that stops
mid-head and one that idles between requests. On expiry the connection ends with **nothing written**: the peer
has sent no byte within the bound, so a status line would be a claim about a request that may not have arrived
at all. What it does **not** bound is a handler that never returns (cancellation is W5's and W7's item),
`Listener.accept`, or the total time to a complete head — a peer that sends one byte before each deadline keeps
the connection alive indefinitely.

**A handler that returns `error` is answered, not re-raised.** The machine's own
`closeWithError .internalServerError` puts `500` + `Connection: close` + `Content-Length: 0` on the wire and
stops accepting input, so the connection halts once those bytes are flushed. The caught `IO.Error` is dropped:
the accept loops discard per-connection results, and a plain-function handler has nowhere to notify.

**Every socket operation comes back as a value rather than a panic** (`LeanIn/Runtime/Net.lean`), so a peer that
goes away mid-request ends the connection as an `error`. A failed socket operation short-circuits out of the
loop and past `Conn.shutdown`; a *handler* failure no longer does, because it is answered inside the loop.
-/

open LeanIn.Http

namespace LeanIn.Runtime.Http

/-- A request handler of ours: the parsed request head to the response head and its fully-buffered body, in
our task monad. A plain function rather than the shipped `Handler` class: the class's other members are
streaming and 100-continue concerns this driver does not carry yet, while the call shape — dispatch on the
parsed request head, return the response — is the same. -/
abbrev Handler := H1.Head → Task.EAsync IO.Error (H1.ResponseHead × ByteArray)

/-- **The driver's own configuration**: the protocol's limits, the clock the read deadline is read from, and the
deadline itself. `h1` is handed to the machine unchanged and is the only thing that reaches it; the clock is
read by `withTimeout` alone, so no clock value — and therefore no `Date` header — can enter the encoder. -/
structure Config where
  /-- The protocol's limits, defaults and all. -/
  h1           : H1.Limits := {}
  /-- The clock `stallTimeout` is measured on. -/
  clock        : Clock
  /-- The longest a single read may wait for bytes or EOF. -/
  stallTimeout : Std.Time.Millisecond.Offset := 12000

/-- **The read → feed → step → dispatch → write cycle for one connection.**

`machine.step` advances the protocol and yields the bytes it wants written and the events it produced; the
output goes out verbatim, an `endHeaders` event is the one place the handler runs, and no other event is acted
on — the reset that begins the next exchange is the machine's own. The loop ends on `machine.halted`, steps
again when the step itself made progress — it wrote bytes, or handled an event other than `needMoreData`, which
the machine re-emits on every starved step — and otherwise **reads**, so the read is the default branch and no
iteration can return to the same machine state without writing or reading. The read carries the deadline, so
even a machine the driver cannot advance cannot hold a carrier indefinitely.

`partial` because a connection has no bound, and `Async` is `Inhabited`; the recursion is the loop. -/
private partial def drive (hooks : Hooks) (cfg : Config) (c : Conn) (handler : Handler)
    (machine : H1.Machine) : Task.EAsync IO.Error Unit := do
  let (machine', step) := machine.step
  if step.output.size > 0 then
    Conn.sendAll c hooks step.output.data
  let mut machine := machine'
  for event in step.events do
    match event with
    | .endHeaders head =>
      -- The handler's failure is answered rather than raised: the response the peer reads is the observable,
      -- and nothing above this loop reads a per-connection error.
      let answered ← try
          let (respHead, body) ← handler head
          machine := machine.send respHead
            |>.sendData #[body]
            |>.userClosedBody
          pure true
        catch _ => pure false
      if !answered then
        machine := machine.closeWithError 500
    | _ => pure ()
  if machine.halted then
    pure ()
  else if step.output.size > 0 || step.events.any (fun e => match e with
      | .needMoreData => false
      | _ => true) then
    drive hooks cfg c handler machine
  else
    match ← Task.EAsync.ofAsync (withTimeout cfg.clock cfg.stallTimeout (Conn.recv c hooks)) with
    | none                 => pure ()              -- the peer stalled: end the connection, nothing written
    | some (.error e)      => throw e              -- a failed socket operation is a value that ends it
    | some (.ok none)      => drive hooks cfg c handler (machine.noMoreInput)
    | some (.ok (some bs)) => drive hooks cfg c handler (machine.feed bs)

/-- **Serve one connection**: run `drive` from a fresh machine built from `cfg.h1` alone, then shut the write
side down so the peer reads the responses to end of stream. The connection outlives a single exchange: it ends
when the machine halts (`Connection: close`, a protocol failure, a failure answer) or when the peer closes or
stalls past `cfg.stallTimeout`.

The machine is built as `{ config := cfg.h1 }`: `agentName` keeps its `none` default and `instant` is left
`none`, so no `Server` and no `Date` header can enter the encoder and the response is a function of the request
and the handler's head. `Std.Http.Server.Config` and every `Std.Http.Server` type stay off this path, as does
any `Std.Http.Transport` instance — `Transport` is typed over `Async`, which would hand the driver a stock-typed
socket and put the work back on the pool. -/
def serveConn (hooks : Hooks) (config : Config) (c : Conn) (handler : Handler) :
    Task.EAsync IO.Error Unit := do
  drive hooks config c handler ({ limits := config.h1 } : H1.Machine)
  Conn.shutdown c hooks

end LeanIn.Runtime.Http
