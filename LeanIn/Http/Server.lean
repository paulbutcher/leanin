module

public import Std.Http.Data
public import LeanIn.Http.H1
public import LeanIn.Runtime.Net
public import LeanIn.Runtime.Io
public import LeanIn.Runtime.Clock
public import LeanIn.Runtime.Time
public import LeanIn.Runtime.VM
public import LeanIn.Async
public import LeanIn.Task.Error

public section

/-!
# The HTTP/1.1 service driver, compiled

The per-connection loop below (`drive`) is an `async`: every suspension in it is a **state of a compiled
machine**, not a closure, so a request costs a step and a raw resume rather than a `bind`, a cell and an item.
The protocol is `LeanIn.Http.H1` — our own parser and machine, in `LeanIn/Http/H1.lean` — so nothing here scans
bytes and there is no framer. The accept loops in `LeanIn.Runtime.Net` are the callers.

**A handler that raises** is answered rather than re-raised: `VM.attempt` turns the raise into a value the loop
sees, and the machine puts `500` + `Connection: close` on the wire with `closeWithError`.

**A transport failure is not a raise.** Inside the streaming request scope the body reader and the response
writer treat the socket's own failures — a peer that half-closes mid-body, a stall, a send that cannot reach the
peer — as a VM **abort**. It passes every `tryE`/`VM.attempt` and every middleware untouched: the scope turns it
into an `aborted` outcome, and the driver closes the connection and reports the transport error, attempting **no
further response** — no 500, no keep-alive. What was already written cannot be retracted: a response head or body
bytes sent before the failure, or the surviving prefix of a failed send, are on the wire. The driver's **own** raw
operations outside that scope — its output sends, its reads between requests, and the close — are not VM effects.
A failed send or read there prompts a close attempt and reports the transport error; a close the shim refuses is
reported as its own error, so neither path establishes that the connection closed.
The buffered entrypoint (`drive`/`serveConn`) keeps the ordinary-error behaviour it has — it exposes no streaming
reader or writer, and an explicit `VM.abort` in one of its handlers has **no** scope to close it: the abort
reaches `runToCell`'s runner and fails loudly where the machine resumes, which is a bug in such a handler rather
than a cancellation.

**What the deadline bounds.** `Config.stallTimeout` is passed to `recvTimeoutRaw`, so the interval between
asking the socket for bytes and bytes-or-EOF arriving is bounded. On expiry the connection ends with **nothing
written**: the peer sent no byte within the bound, so a status line would be a claim about a request that may
never have arrived. What it does not bound is a handler that never returns, `Listener.accept`, or the total time
to a complete head — a peer that sends one byte before each deadline keeps the connection alive.
-/

namespace LeanIn.Http.Server

open LeanIn.Runtime
open LeanIn.Http

/-- A request handler of ours: the parsed request head to the response head and its fully buffered body, in the
`VM`. It may suspend, and its suspension is a suspension of the connection's machine. -/
abbrev Handler := H1.Head → ByteArray → VM (H1.ResponseHead × ByteArray)

namespace Handler
/-- Lift a pure handler to an async one: its computation is just `pure`, which `pump` answers inline. -/
def ofPure (h : H1.Head → H1.ResponseHead × ByteArray) : Handler := fun head _ => pure (h head)
end Handler

/-- **The driver's own configuration**: the protocol's limits, the clock the read deadline is read from, and the
deadline itself. `h1` is handed to the machine unchanged and is the only thing that reaches it, so no clock
value can enter the encoder. -/
structure Config where
  /-- The protocol's limits, defaults and all. -/
  h1           : H1.Limits := {}
  /-- The clock `stallTimeout` is measured on. -/
  clock        : Clock
  /-- The longest a single read may wait for bytes or EOF. -/
  stallTimeout : Std.Time.Millisecond.Offset := 12000

/-- Whether a step got anywhere: it wrote bytes, or handled an event other than `needMoreData`, which the
machine re-emits on every starved step. The loop reads only when this is false, so no iteration can return to
the same machine state without writing or reading. -/
def madeProgress (before after : H1.Machine) (encoded : Nat) (events : Array H1.Event) : Bool :=
  encoded > 0 ||
  before.pos != after.pos ||
  before.chunkState != after.chunkState ||
  before.bodyDone != after.bodyDone ||
  events.any fun e => match e with
    | .needMoreData => false
    | _ => true

/-- Which of three things the pure pump stopped for. -/
inductive Stop where
  | needHandler
  | needRead
  | done
deriving Inhabited, BEq, Repr

/-- What the pump stopped with: the machine to continue from, the bytes it wants written, and -- for
`needHandler` -- the head to hand the handler.

A structure rather than an inductive with arguments, because every field the loop reads then carries its type
from the declaration. The `async` compiler infers a state field's type from its uses and errors with
the field named where uses alone cannot say, which a `match`-bound pattern hits; reading named fields
sidesteps that. -/
structure Pump where
  stop    : Stop := .done
  machine : H1.Machine := {}
  out     : Array ByteArray := #[]
  /-- A complete request whose handler suspends: the head and its buffered body. -/
  req?    : Option (H1.Head × ByteArray) := none
deriving Inhabited

/-- The connection pump, pure: step the machine, accumulate the bytes it wants written, and stop at the first
thing that needs the socket or a handler that suspends. -/
private partial def pumpGo (handler : Handler) (m : H1.Machine) (acc : Array ByteArray) : Pump :=
  if m.halted then { stop := .done, machine := m, out := acc }
  else
    let (m', step) := H1.Machine.step m
    let acc := acc ++ step.output.data
    -- A rejected head (bad syntax, too many headers, a body past the limit) is answered and the connection
    -- closed: the machine cannot return to a parseable state.
    match step.events.find? (fun e => match e with | .failed _ => true | _ => false) with
    | some (.failed e) =>
      let (status, reason) : Nat × String := match e with
        | .bodyTooLarge    => (413, "Payload Too Large")
        | .headersTooLarge => (431, "Request Header Fields Too Large")
        | .badRequest      => (400, "Bad Request")
      -- The failed step halted the machine; clearing that here lets the error response be flushed (the
      -- closing flag halts it again once the bytes are out).
      pumpGo handler ({ m'.closeWithError status reason with halted := false }) acc
    | _ =>
      -- A request is dispatched only when its framing is complete: no body (`Content-Length: 0` at
      -- `endHeaders`) or the whole body accumulated. Dispatch before the next head is parsed, or the
      -- following request's bytes would be consumed as this one's body by a later `step`.
      if m'.head?.isSome && m'.bodyDone then
        let (head, body, m'') := m'.takeRequest
        match handler head body with
        | .pure (respHead, respBody) =>
          pumpGo handler (m''.send respHead |>.sendData #[respBody] |>.userClosedBody) acc
        | _ => { stop := .needHandler, machine := m'', out := acc, req? := some (head, body) }
      else if m'.halted then { stop := .done, machine := m', out := acc }
      else if madeProgress m m' step.output.size step.events then pumpGo handler m' acc
      else { stop := .needRead, machine := m', out := acc }

/-- The pump from a fresh accumulator. -/
def pump (handler : Handler) (m : H1.Machine) : Pump := pumpGo handler m #[]

-- **The connection loop**, as a compiled machine.
--
-- `pump` runs the pure part; the output goes out verbatim; an `endHeaders` whose handler suspends is the one
-- place the handler runs, and the loop then branches on what it answered. The loop ends when the machine halts,
-- and otherwise **reads**, so the read is the default branch and the deadline covers it.
--
-- A docstring here would not parse: `async` is a command syntax registered by `elab`, and that form does
-- not take one.
async def drive (c : LeanIn.Runtime.Conn) (cfg : Config) (handler : Handler)
    (m : LeanIn.Http.H1.Machine) : Unit := do
  let r : Pump := pump handler m
  let machine : H1.Machine := r.machine
  let out : Array ByteArray := r.out
  match r.stop with
  | .needHandler =>
    if out.size > 0 then
      let sw := await (LeanIn.Runtime.Io.sendAllRaw c out)
      match sw with
      | .error e =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        throw (if closed then e else .userError s!"{e}; and the shim refused the cleanup close")
      | .ok _ => pure ()
    let req : H1.Head × ByteArray := r.req?.getD (default, .empty)
    let head : H1.Head := req.1
    let body : ByteArray := req.2
    let answered := await (LeanIn.Runtime.VM.runAsync (VM.attempt (handler head body)))
    match answered with
    | .ok (respHead, body) =>
      let m := H1.Machine.send machine respHead |>.sendData #[body] |>.userClosedBody
      recurse
    | .error _ =>
      let m := H1.Machine.closeWithError machine 500
      recurse
  | .needRead =>
    if out.size > 0 then
      let sw := await (LeanIn.Runtime.Io.sendAllRaw c out)
      match sw with
      | .error e =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        throw (if closed then e else .userError s!"{e}; and the shim refused the cleanup close")
      | .ok _ => pure ()
    -- A live clock's deadline is a slot the driver sweeps on its own poll timeout; a harness clock's is an
    -- armed instant the virtual driver advances to, and it must be retired exactly.
    if cfg.clock.swept then
      let rt := await (LeanIn.Runtime.Io.recvStallRaw c cfg.stallTimeout 65536)
      match rt with
      | none =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        if closed then return () else throw (.userError "Io.closeRaw: the loop refused the connection's close submission")
      | some (.error e) =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        throw (if closed then e else .userError s!"{e}; and the shim refused the cleanup close")
      | some (.ok none) =>
        let m := H1.Machine.noMoreInput machine
        recurse
      | some (.ok (some bs)) =>
        let m := H1.Machine.feed machine bs
        recurse
    else
      let rt := await (LeanIn.Runtime.Io.recvTimeoutRaw c cfg.clock.schedule cfg.stallTimeout 65536)
      match rt with
      | none =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        if closed then return () else throw (.userError "Io.closeRaw: the loop refused the connection's close submission")
      | some (.error e) =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        throw (if closed then e else .userError s!"{e}; and the shim refused the cleanup close")
      | some (.ok none) =>
        let m := H1.Machine.noMoreInput machine
        recurse
      | some (.ok (some bs)) =>
        let m := H1.Machine.feed machine bs
        recurse
  | .done =>
    if out.size > 0 then
      let sw := await (LeanIn.Runtime.Io.sendAllRaw c out)
      match sw with
      | .error e =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        throw (if closed then e else .userError s!"{e}; and the shim refused the cleanup close")
      | .ok _ => pure ()
    let closed := await (LeanIn.Runtime.Io.closeRaw c)
    if closed then return () else throw (.userError "Io.closeRaw: the loop refused the connection's close submission")


/-! ## Streaming session

The buffered `Handler` above hands the application the whole body and takes the whole response back. The
session below is the port's body boundary: the handler reads the request body incrementally (the bytes already
in the machine's buffer first, then the socket) and writes the response incrementally, so neither direction is
bounded by `Limits.maxBody`. Reads and writes are LeanIn effects on the same connection, which is what lets a
handler park on a body byte that only the peer can send without deadlocking the connection. A failed read or
write is **not** a raise the handler can catch: it is a typed VM abort, which passes middleware `try`/`VM.attempt`
and reaches the handler's request scope, so the driver closes the connection and reports the transport error,
attempting no further 500 or response. Bytes already sent — a started head, body bytes, or the prefix of a failed
send — are not retracted: a half-closed peer can still read what reached it. -/

/-- The decoder's position in a request body. -/
structure BodyState where
  /-- Bytes not yet decoded; `pos` is how far the decoder has read. -/
  buf : ByteArray := .empty
  pos : Nat := 0
  /-- Fixed-length bytes still expected, when the body is `Content-Length` framed. -/
  remaining : Option Nat := none
  /-- The chunk decoder's state, when the body is chunked. -/
  chunk : Option H1.ChunkState := none
  /-- The body has ended. -/
  done : Bool := true
  /-- Bytes after the body's end: a pipelined next request, handed back to the machine. -/
  leftover : ByteArray := .empty
  /-- Body bytes already handed to the handler. -/
  seen : Nat := 0
  /-- The most body bytes this reader will hand over. -/
  limit : Nat := 1048576
  /-- A declared `Content-Length` already over the limit: fail on the first read. -/
  tooLarge : Bool := false
deriving Inhabited

/-- The error a body read raises when the request exceeds `Config.h1.maxBody`. The stream driver maps it
to `413 Payload Too Large` rather than its generic 500. -/
def bodyTooLarge : IO.Error := .userError "Http: request body exceeds maxBody"

/-- Whether a handler's failure is the body-limit error. -/
def isBodyTooLarge (e : IO.Error) : Bool := e.toString == bodyTooLarge.toString

/-- A request body as the handler sees it: `recv n` returns at most `n` bytes, then `none` at the end. The
reader enforces `Config.h1.maxBody` itself, so `readAll` cannot grow past the configured ceiling. A
transport failure, a stall or the peer closing mid-body **aborts**: the handler's `try`/`VM.attempt` cannot see
it, so a peer that disconnects mid-body ends the connection rather than looking like an EOF or an application
error the handler could answer. -/
structure BodyReader where
  recv : Nat → VM (Option ByteArray)
  /-- Whether the whole body has been consumed. An unread body closes the connection instead of being parsed as
  the next request. -/
  drained : VM Bool
  /-- Bytes after the body: the machine resumes from these when the connection is reused. -/
  leftover : VM ByteArray
  /-- The peer's address, when the shim can read it. -/
  peer : Option Std.Net.SocketAddress := none

namespace BodyReader

/-- Read the whole body through the reader. A stock `Body.Stream` client's `readAll` maps to this; it
accumulates, so it is for bounded bodies, while `recv` is the streaming path. -/
partial def readAllLoop (r : BodyReader) (acc : ByteArray) : VM ByteArray := do
  match ← r.recv 65536 with
  | some chunk => readAllLoop r (acc ++ chunk)
  | none => pure acc

def readAll (r : BodyReader) : VM ByteArray := readAllLoop r .empty

/-- A stateful chunk transform over a body: the native counterpart of `BodyExt.Transform`, without the stock
`Async`/`StateT` machinery. Each `recv` applies `f` to the chunk with the running state. -/
def mapState (r : BodyReader) (f : σ → ByteArray → VM (σ × ByteArray)) (init : σ) :
    IO BodyReader := do
  let st ← IO.mkRef init
  return {
    r with
    recv := fun n => do
      match ← r.recv n with
      | none => pure none
      | some chunk => do
        let s ← (monadLift (BaseIO.toIO st.get) : VM σ)
        let (s', out) ← f s chunk
        monadLift (BaseIO.toIO (st.set s') : VM Unit)
        pure (some out)
  }

/-- A stateless chunk transform. -/
def map (r : BodyReader) (f : ByteArray → ByteArray) : IO BodyReader :=
  r.mapState (fun _ chunk => pure ((), f chunk)) ()

end BodyReader

/-- A response body as the handler writes it. `start` sends the head and fixes the framing: a declared
`Content-Length`, else chunked on HTTP/1.1, else close-delimited. A transport failure in any of the three sends
— the head, a body chunk, the terminating chunk of `finish` — aborts rather than raising: there is no peer left
to answer. The state checks (a body before its head, a body after `finish`) stay ordinary raises, because those
are the handler's mistakes, not the transport's. -/
structure ResponseWriter where
  /-- Send an interim `100 Continue` (used when the driver's own `autoContinue` is off). -/
  sendContinue : VM Unit
  start : H1.ResponseHead → VM Unit
  write : ByteArray → VM Unit
  finish : VM Unit
  /-- Whether the response was started and finished, and whether it is chunked. -/
  status : VM (Bool × Bool × Bool)
  /-- The status code of the head sent by `start`, if any. -/
  code : VM (Option Nat)

/-- A streaming request handler: the head, the body reader, and the response writer. -/
abbrev StreamHandler := H1.Head → BodyReader → ResponseWriter → VM Unit

namespace Stream

def hexOf (n : Nat) : String :=
  String.mk (Nat.toDigits 16 n)

/-- Read a state reference as a `VM` effect. -/
def liftGet {α : Type} (r : IO.Ref α) : VM α := monadLift (r.get : IO α)

/-- Write a state reference as a `VM` effect. -/
def liftSet {α : Type} (r : IO.Ref α) (a : α) : VM Unit := monadLift (r.set a : IO Unit)

/-- `recv` over a body state: decode from the buffer, reading the socket only when it runs out. -/
partial def recvSome (st : IO.Ref BodyState) (c : Conn) (clock : Clock)
    (stall : Std.Time.Millisecond.Offset) (n : Nat) : VM (Option ByteArray) := do
  let s ← (liftGet st)
  if s.tooLarge then throw bodyTooLarge
  if s.done then
    liftSet st { s with leftover := s.buf.extract s.pos s.buf.size }
    return none
  if s.pos >= s.buf.size then
    let rt ← VM.recvTimeoutTransport c clock stall
    match rt with
    | none => VM.abort (.userError "Http: the peer stalled while sending a request body")
    | some none => VM.abort (.userError "Http: the peer closed while sending a request body")
    | some (some bs) =>
      let s ← (liftGet st)
      liftSet st { s with buf := s.buf ++ bs }
      recvSome st c clock stall n
  else if let some rem := s.remaining then
    let avail := s.buf.size - s.pos
    let k := min (min n rem) avail
    let data := s.buf.extract s.pos (s.pos + k)
    let rem' := rem - k
    let done := rem' == 0
    let leftover := if done then s.buf.extract (s.pos + k) s.buf.size else .empty
    if s.seen + k > s.limit then throw bodyTooLarge
    liftSet st { s with pos := s.pos + k, remaining := some rem', done, leftover, seen := s.seen + k }
    return some data
  else match s.chunk with
  | some H1.ChunkState.sizeLine =>
    match H1.findLF s.buf s.pos with
    | none =>
      let rt ← VM.recvTimeoutTransport c clock stall
      match rt with
      | none => VM.abort (.userError "Http: the peer stalled in a chunk-size line")
      | some none => VM.abort (.userError "Http: the peer closed in a chunk-size line")
      | some (some bs) =>
        let s ← (liftGet st)
        liftSet st { s with buf := s.buf ++ bs }
        recvSome st c clock stall n
    | some nl =>
      let lineStop := if nl > s.pos && s.buf.get! (nl - 1) == 0x0D then nl - 1 else nl
      match H1.chunkSize? s.buf s.pos lineStop with
      | none => throw (.userError "Http: malformed chunk size")
      | some 0 =>
        liftSet st { s with pos := nl + 1, chunk := some .trailers }
        recvSome st c clock stall n
      | some sz =>
        liftSet st { s with pos := nl + 1, chunk := some (.data sz) }
        recvSome st c clock stall n
  | some (.data rem) =>
    let avail := s.buf.size - s.pos
    if avail == 0 then
      let rt ← VM.recvTimeoutTransport c clock stall
      match rt with
      | none => VM.abort (.userError "Http: the peer stalled in a chunk")
      | some none => VM.abort (.userError "Http: the peer closed in a chunk")
      | some (some bs) =>
        let s ← (liftGet st)
        liftSet st { s with buf := s.buf ++ bs }
        recvSome st c clock stall n
    else
      let k := min (min n rem) avail
      let data := s.buf.extract s.pos (s.pos + k)
      let rem' := rem - k
      if s.seen + k > s.limit then throw bodyTooLarge
      let st' := if rem' == 0 then { s with pos := s.pos + k, chunk := some .dataCRLF, seen := s.seen + k }
                 else { s with pos := s.pos + k, chunk := some (.data rem'), seen := s.seen + k }
      liftSet st st'
      return some data
  | some .dataCRLF =>
    if s.buf.size - s.pos < 2 then
      let rt ← VM.recvTimeoutTransport c clock stall
      match rt with
      | none => VM.abort (.userError "Http: the peer stalled after a chunk")
      | some none => VM.abort (.userError "Http: the peer closed after a chunk")
      | some (some bs) =>
        let s ← (liftGet st)
        liftSet st { s with buf := s.buf ++ bs }
        recvSome st c clock stall n
    else
      liftSet st { s with pos := s.pos + 2, chunk := some .sizeLine }
      recvSome st c clock stall n
  | some .trailers =>
    match H1.findLF s.buf s.pos with
    | none =>
      let rt ← VM.recvTimeoutTransport c clock stall
      match rt with
      | none => VM.abort (.userError "Http: the peer stalled in trailers")
      | some none => VM.abort (.userError "Http: the peer closed in trailers")
      | some (some bs) =>
        let s ← (liftGet st)
        liftSet st { s with buf := s.buf ++ bs }
        recvSome st c clock stall n
    | some nl =>
      let lineStop := if nl > s.pos && s.buf.get! (nl - 1) == 0x0D then nl - 1 else nl
      if lineStop == s.pos then
        liftSet st { s with pos := nl + 1, chunk := some .done, done := true,
                                   leftover := s.buf.extract (nl + 1) s.buf.size }
        return none
      else
        liftSet st { s with pos := nl + 1 }
        recvSome st c clock stall n
  | some .done =>
    liftSet st { s with done := true, leftover := s.buf.extract s.pos s.buf.size }
    return none
  | none => throw (.userError "Http: body framing lost")

/-- Build the reader for a head and the bytes already buffered behind it. -/
def bodyReader (head : H1.Head) (initial : ByteArray) (c : Conn) (clock : Clock)
    (stall : Std.Time.Millisecond.Offset) (limit : Nat) : IO BodyReader := do
  let chunked := H1.chunked? head
  let cl := if chunked then 0 else (H1.contentLength? head.buf head.headers).getD 0
  let st ← IO.mkRef ({ buf := initial
                       remaining := if chunked then none else some cl
                       chunk := if chunked then some .sizeLine else none
                       done := !chunked && cl == 0
                       limit
                       tooLarge := !chunked && cl > limit } : BodyState)
  let peer ← LeanIn.Runtime.peerAddr c
  return {
    peer
    recv := fun n => recvSome st c clock stall n
    drained := (do
      let s ← (liftGet st)
      return s.done)
    leftover := (do
      let s ← (liftGet st)
      return s.leftover)
  }

/-- The writer for one response on `c`. Framing is chosen once, at `start`. -/
def responseWriter (c : Conn) (version : H1.Version) (keepAlive : Bool) : IO ResponseWriter := do
  let st ← IO.mkRef ((false, false, (none : Option Bool), (none : Option Nat)) :
    Bool × Bool × Option Bool × Option Nat)
  let set (f : Bool × Bool × Option Bool × Option Nat → Bool × Bool × Option Bool × Option Nat) : VM Unit := do
    let s ← (liftGet st)
    liftSet st (f s)
  return {
    sendContinue := VM.sendAllTransport c #[H1.continueBytes]
    start := fun rh => do
      let declared := rh.headers.any (fun (n, _) => n.toLower == "content-length")
      let closeAsked := rh.headers.any (fun (n, v) =>
        n.toLower == "connection" && (v.splitOn ",").any (fun t => t.trimAscii.toString.toLower == "close"))
      let chunked := !declared && version == .v11
      let rh := { rh with headers := rh.headers.filter (fun (n, _) => n.toLower != "transfer-encoding") }
      let rh := if chunked then { rh with headers := rh.headers.push ("Transfer-Encoding", "chunked") } else rh
      let rh := if closeAsked then { rh with headers := rh.headers.push ("Connection", "close") } else rh
      VM.sendAllTransport c #[H1.encodeResponseHead rh]
      set (fun _ => (true, false, some chunked, some rh.status))
    write := fun bs => do
      let s ← (liftGet st)
      match s with
      | (false, _, _, _) => throw (.userError "Http: response body written before its head")
      | (_, true, _, _) => throw (.userError "Http: response body written after finish")
      | (_, false, some true, _) =>
        VM.sendAllTransport c #[s!"{hexOf bs.size}\r\n".toUTF8, bs, "\r\n".toUTF8]
      | (_, false, _, _) => VM.sendTransport c bs
    finish := do
      let s ← (liftGet st)
      match s with
      | (false, _, _, _) => pure ()
      | (_, true, _, _) => pure ()
      | (_, false, some true, _) =>
        VM.sendAllTransport c #["0\r\n\r\n".toUTF8]
        set (fun (a, _, b, c) => (a, true, b, c))
      | (_, false, _, _) => set (fun (a, _, b, c) => (a, true, b, c))
    status := do
      let s ← (liftGet st)
      return (s.1, s.2.1, s.2.2.1.getD false)
    code := do
      let s ← (liftGet st)
      return s.2.2.2
  }

/-- One buffered response through the writer, for handlers that already hold the whole body. -/
def respond (w : ResponseWriter) (rh : H1.ResponseHead) (body : ByteArray) : VM Unit := do
  let rh := if rh.headers.any (fun (n, _) => n.toLower == "content-length") then rh
            else { rh with headers := rh.headers.push ("Content-Length", toString body.size) }
  w.start rh
  w.write body
  w.finish

end Stream

/-- The streaming pump: stop at the head, before the body is consumed, and hand the decoder the bytes already
read. The machine is left at the end of its buffer; the body decoder owns those bytes until the handler is done,
and returns the bytes after the body as the next request. -/
private partial def pumpStreamGo (m : H1.Machine) (acc : Array ByteArray) : Pump :=
  if m.halted then { stop := .done, machine := m, out := acc }
  else
    let (m', step) := H1.Machine.step m
    let acc := acc ++ step.output.data
    match step.events.find? (fun e => match e with | .failed _ => true | _ => false) with
    | some (.failed e) =>
      let (status, reason) : Nat × String := match e with
        | .bodyTooLarge    => (413, "Payload Too Large")
        | .headersTooLarge => (431, "Request Header Fields Too Large")
        | .badRequest      => (400, "Bad Request")
      pumpStreamGo ({ m'.closeWithError status reason with halted := false }) acc
    | _ =>
      if m'.head?.isSome then
        let head := m'.head?.getD default
        let initial := m'.buf.extract m'.pos m'.buf.size
        let acc := acc ++ m'.out                 -- an interim `100 Continue` queued at the head
        let m'' := { m' with head? := none, pos := m'.buf.size, bodyRemaining := 0, out := #[],
                             chunkState := none, bodyDone := true, reqBody := .empty }
        { stop := .needHandler, machine := m'', out := acc, req? := some (head, initial) }
      else if m'.halted then { stop := .done, machine := m', out := acc }
      else if madeProgress m m' step.output.size step.events then pumpStreamGo m' acc
      else { stop := .needRead, machine := m', out := acc }

/-- The streaming connection loop. The head is dispatched as soon as it parses; the body and the response are
the handler's to read and write, so neither is buffered. The connection is reused only when the body was fully
read, the response was started and finished, and the machine's disposition keeps it alive. -/
async def driveStream (c : LeanIn.Runtime.Conn) (cfg : Config) (handler : StreamHandler)
    (m : LeanIn.Http.H1.Machine) : Unit := do
  let r : Pump := pumpStreamGo m #[]
  let machine : H1.Machine := r.machine
  let out : Array ByteArray := r.out
  match r.stop with
  | .needHandler =>
    if out.size > 0 then
      let sw := await (LeanIn.Runtime.Io.sendAllRaw c out)
      match sw with
      | .error e =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        throw (if closed then e else .userError s!"{e}; and the shim refused the cleanup close")
      | .ok _ => pure ()
    let req : H1.Head × ByteArray := r.req?.getD (default, .empty)
    let head : H1.Head := req.1
    let initial : ByteArray := req.2
    let answered : Outcome (Bool × ByteArray × (Bool × Bool × Bool)) :=
      await (LeanIn.Runtime.VM.runAsync (VM.requestScope (do
      let reader ← (monadLift (Stream.bodyReader head initial c cfg.clock cfg.stallTimeout cfg.h1.maxBody) : VM BodyReader)
      let writer ← (monadLift (Stream.responseWriter c head.version machine.keepAlive) : VM ResponseWriter)
      let chunked := H1.chunked? head
      let declared := if chunked then 0 else (H1.contentLength? head.buf head.headers).getD 0
      if !chunked && declared > cfg.h1.maxBody then
        -- The head is the only place the driver learns the size before the handler writes; rejecting here
        -- means the 413 is not sent after a handler has already begun its response.
        Stream.respond writer { status := 413, reason := "Payload Too Large" } "".toUTF8
        let st ← writer.status
        return (false, ByteArray.empty, st)
      try
        handler head reader writer
      catch e =>
        let st ← writer.status
        if !st.1 then
          if isBodyTooLarge e then
            Stream.respond writer { status := 413, reason := "Payload Too Large" } "".toUTF8
          else
            Stream.respond writer { status := 500, reason := "Internal Server Error" } "".toUTF8
        throw e
      let drained ← reader.drained
      let left ← reader.leftover
      let st ← writer.status
      if !st.1 then
        -- The handler answered nothing: the driver's own 500 is sent **inside this request's scope**, so a
        -- transport failure sending it takes the abort channel and still reaches the driver's `aborted` branch,
        -- which closes the connection and reports the transport error. Sending it outside the scope would let an
        -- abort escape `VM.attempt` and `runToCell`'s runner, leaving the connection unclosed.
        Stream.respond writer { status := 500, reason := "Internal Server Error" } "".toUTF8
      let st' ← writer.status
      return (drained, left, st'))))
    match answered with
    | .ok res =>
      let drained : Bool := res.1
      let left : ByteArray := res.2.1
      let st : Bool × Bool × Bool := res.2.2
      let finished : Bool := st.2.1
      if drained && finished && machine.keepAlive then
        let m := H1.Machine.feed { machine with buf := .empty, pos := 0 } left
        recurse
      else
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        if closed then return () else throw (.userError "Io.closeRaw: the loop refused the connection's close submission")
    | .error e =>
      let closed := await (LeanIn.Runtime.Io.closeRaw c)
      throw (if closed then e else .userError s!"{e}; and the shim refused the cleanup close")
    | .aborted reason =>
      -- The request's own cancellation: the transport cannot carry this request's completion, so no further
      -- response — no 500, no keep-alive — is attempted, and the connection's outcome is the transport failure.
      -- Bytes already sent stand and are not retracted; the peer may still be able to read them.
      let closed := await (LeanIn.Runtime.Io.closeRaw c)
      throw (if closed then reason else .userError s!"{reason}; and the shim refused the cleanup close")
  | .needRead =>
    if out.size > 0 then
      let sw := await (LeanIn.Runtime.Io.sendAllRaw c out)
      match sw with
      | .error e =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        throw (if closed then e else .userError s!"{e}; and the shim refused the cleanup close")
      | .ok _ => pure ()
    if cfg.clock.swept then
      let rt := await (LeanIn.Runtime.Io.recvStallRaw c cfg.stallTimeout 65536)
      match rt with
      | none =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        if closed then return () else throw (.userError "Io.closeRaw: the loop refused the connection's close submission")
      | some (.error e) =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        throw (if closed then e else .userError s!"{e}; and the shim refused the cleanup close")
      | some (.ok none) =>
        let m := H1.Machine.noMoreInput machine
        recurse
      | some (.ok (some bs)) =>
        let m := H1.Machine.feed machine bs
        recurse
    else
      let rt := await (LeanIn.Runtime.Io.recvTimeoutRaw c cfg.clock.schedule cfg.stallTimeout 65536)
      match rt with
      | none =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        if closed then return () else throw (.userError "Io.closeRaw: the loop refused the connection's close submission")
      | some (.error e) =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        throw (if closed then e else .userError s!"{e}; and the shim refused the cleanup close")
      | some (.ok none) =>
        let m := H1.Machine.noMoreInput machine
        recurse
      | some (.ok (some bs)) =>
        let m := H1.Machine.feed machine bs
        recurse
  | .done =>
    if out.size > 0 then
      let sw := await (LeanIn.Runtime.Io.sendAllRaw c out)
      match sw with
      | .error e =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        throw (if closed then e else .userError s!"{e}; and the shim refused the cleanup close")
      | .ok _ => pure ()
    let closed := await (LeanIn.Runtime.Io.closeRaw c)
    if closed then return () else throw (.userError "Io.closeRaw: the loop refused the connection's close submission")

/-- Serve a streaming handler on one connection. -/
def serveConnStream (cfg : Config) (c : Conn) (handler : StreamHandler) : Task.EAsync IO.Error Unit :=
  driveStream c cfg handler ({ limits := cfg.h1, buffered := false } : H1.Machine)

/-- **Serve one connection**: run the compiled loop from a fresh machine built from `cfg.h1` alone. The
connection outlives a single exchange -- it ends when the machine halts, or when the peer closes or stalls past
`cfg.stallTimeout`. The returned computation completes only when the machine's terminal close fires `onClose`:
`Conn.serve` owns the socket by the body's lifetime, so the body must span the connection, not its first
suspension. One `Join` cell per connection -- never one per request. The cell carries the connection's
**outcome**: a clean close is `.ok`, a transport failure is the error, so a reset is never reported as a
success -- the shape the accept loops' registries and drains already account by. -/
def serveConn (cfg : Config) (c : Conn) (handler : Handler) : Task.EAsync IO.Error Unit :=
  drive c cfg handler ({ limits := cfg.h1 } : H1.Machine)

end LeanIn.Http.Server
end
