module

public import Std

public section

/-!
# `LeanIn.Http.H1` — a byte-oriented HTTP/1.1 head parser and connection machine

A replacement for `Std.Http.Protocol.H1`'s request path. Where Std's parser is a `Parsec` combinator parser that
converts each scanned token back into a `ByteArray` then a `String` (and re-allocates `"\r\n".toUTF8` literals on
every line), this one **scans the read buffer in place** and keeps the request-target and every header name/value
as a `Slice` — a pair of indices into that buffer. No per-line literal, no `String`, no backtracking; the method
is dispatched on its first byte rather than tried against 40 `attempt`-wrapped alternatives.

Body framing is **Content-Length only** here; chunked transfer and `Expect: 100-continue` are follow-ups, and the
header limits are not yet enforced.
-/

namespace LeanIn.Http.H1

/-- A half-open range of indices into a `ByteArray` — a view, not a copy. -/
structure Slice where
  start : Nat
  stop : Nat
deriving Inhabited, Repr, BEq, DecidableEq

namespace Slice
/-- The slice's length. -/
@[inline] def size (s : Slice) : Nat := s.stop - s.start
/-- The slice's bytes, copied out (only where a copy is genuinely wanted). -/
@[inline] def toByteArray (buf : ByteArray) (s : Slice) : ByteArray := buf.extract s.start s.stop
/-- The slice as a `String`, `none` if not valid UTF-8. -/
def toString? (buf : ByteArray) (s : Slice) : Option String :=
  String.fromUTF8? (toByteArray buf s)
/-- Byte equality of the slice with `bs` (for header-name/value lookup against a known byte string). -/
def eqBytes (buf : ByteArray) (sl : Slice) (bs : ByteArray) : Bool :=
  sl.size == bs.size && Id.run do
    let mut ok := true
    for i in [0:sl.size] do
      ok := ok && buf.get! (sl.start + i) == bs.get! i
    return ok
/-- Case-insensitive ASCII byte equality (header names are case-insensitive). -/
def eqBytesCI (buf : ByteArray) (sl : Slice) (bs : ByteArray) : Bool :=
  sl.size == bs.size && Id.run do
    let mut ok := true
    for i in [0:sl.size] do
      let c := buf.get! (sl.start + i)
      let l := if c ≥ 0x41 && c ≤ 0x5A then c + 0x20 else c
      let d := bs.get! i
      let e := if d ≥ 0x41 && d ≤ 0x5A then d + 0x20 else d
      ok := ok && l == e
    return ok
end Slice

/-- The request methods we dispatch on, plus `other`. -/
inductive Method where
  | get | head | post | put | delete | options | patch | trace | connect | other
deriving Inhabited, Repr, BEq, DecidableEq

/-- The HTTP version we accept. -/
inductive Version where
  | v10 | v11
deriving Inhabited, Repr, BEq, DecidableEq

/-- A parsed request head. `target` and every header name/value are **views** into `buf`, the read buffer this
head was parsed from, which rides along so the head is self-contained: `targetString`/`headerValue?` resolve a
view without the caller having to keep the buffer. -/
structure Head where
  buf     : ByteArray := .empty
  /-- The method as the parser classifies it. `Method.other` carries no token, so the raw token is kept in
  `methodToken`: an adapter that must preserve the request method (LeanIO does) reads the token instead of
  collapsing distinct methods into `other`. -/
  method  : Method := .get
  /-- The method token exactly as sent, a view into `buf`. -/
  methodToken : Slice := default
  version : Version := .v11
  target  : Slice := default
  headers : Array (Slice × Slice) := #[]
deriving Inhabited

namespace Head
/-- The request target as a `String`, `none` if not valid UTF-8. -/
def targetString? (h : Head) : Option String := Slice.toString? h.buf h.target
/-- The request target as a `String` (empty if not valid UTF-8). -/
def targetString (h : Head) : String := (h.targetString?).getD ""
/-- The value view of the first header whose name matches `name` (ASCII case-insensitive). -/
def headerSlice? (h : Head) (name : ByteArray) : Option Slice :=
  h.headers.findSome? fun (n, v) => if Slice.eqBytesCI h.buf n name then some v else none
/-- The method token exactly as sent, `none` if it is not valid UTF-8. -/
def methodTokenString? (h : Head) : Option String := Slice.toString? h.buf h.methodToken
/-- The method token exactly as sent (empty if it is not valid UTF-8). -/
def methodTokenString (h : Head) : String := (h.methodTokenString?).getD ""
/-- The value of the first header matching `name` as a `String`. -/
def headerValue? (h : Head) (name : ByteArray) : Option String :=
  (h.headerSlice? name).bind (fun v => Slice.toString? h.buf v)
end Head

/-- The request method as it appears on the wire. -/
def Method.toString : Method → String
  | .get => "GET" | .head => "HEAD" | .post => "POST" | .put => "PUT" | .delete => "DELETE"
  | .options => "OPTIONS" | .patch => "PATCH" | .trace => "TRACE" | .connect => "CONNECT" | .other => "OTHER"

instance : ToString Method := ⟨Method.toString⟩

/-- The version as it appears on the wire. -/
def Version.toString : Version → String
  | .v10 => "HTTP/1.0" | .v11 => "HTTP/1.1"

instance : ToString Version := ⟨Version.toString⟩

/-- Why a head parse did not complete. -/
inductive HeadError where
  | badRequest
  | headersTooLarge
  | bodyTooLarge
deriving Inhabited, Repr, BEq

/-- Where the decoder is in a chunked request body. -/
inductive ChunkState where
  /-- Waiting for a chunk-size line (hex, optionally followed by extensions). -/
  | sizeLine
  /-- Inside a chunk with this many bytes still to come. -/
  | data (remaining : Nat)
  /-- The CRLF that ends a chunk's data. -/
  | dataCRLF
  /-- After the zero-size chunk: trailer lines until the terminating blank line. -/
  | trailers
  /-- Terminated. -/
  | done
deriving Inhabited, Repr, BEq

/-- Limits on a parsed head. -/
structure Limits where
  /-- The most header lines accepted before the head is rejected. -/
  maxHeaders : Nat := 100
  /-- The most messages one connection may serve before keep-alive is dropped. -/
  maxMessages : Nat := 100
  /-- The most request-body bytes buffered before the request is rejected with 413. -/
  maxBody : Nat := 1048576
  /-- Whether the machine writes `100 Continue` itself. A server with a continue policy (routing's
  `onContinue`) turns this off and sends the interim response through the writer instead. -/
  autoContinue : Bool := true
deriving Inhabited

/-- The result of trying to parse a head from a buffer at a position. -/
inductive HeadResult where
  | incomplete
  | ok (head : Head) (rest : Nat)
  | failed (err : HeadError)
deriving Inhabited

/-- Index of the first `\n` at or after `start`. -/
def findLF (buf : ByteArray) (start : Nat) : Option Nat := Id.run do
  let n := buf.size
  let mut i := start
  while i < n do
    if buf.get! i == 0x0A then return some i
    i := i + 1
  return none

/-- The method for the bytes `[start, stop)`: dispatch on the first byte, no chain. -/
def methodOf (buf : ByteArray) (start stop : Nat) : Option Method :=
  let len := stop - start
  let b (i : Nat) : UInt8 := if i < len then buf.get! (start + i) else 0
  if len == 0 then none
  else match b 0 with
  | 0x47 => if len == 3 && b 1 == 0x45 && b 2 == 0x54 then some .get else some .other
  | 0x48 => if len == 4 && b 1 == 0x45 && b 2 == 0x41 && b 3 == 0x44 then some .head else some .other
  | 0x50 => if len == 4 && b 1 == 0x4F && b 2 == 0x53 && b 3 == 0x54 then some .post
            else if len == 3 && b 1 == 0x55 && b 2 == 0x54 then some .put
            else if len == 5 && b 1 == 0x41 && b 2 == 0x54 && b 3 == 0x43 && b 4 == 0x48 then some .patch
            else some .other
  | 0x44 => if len == 6 && b 1 == 0x45 && b 2 == 0x4C && b 3 == 0x45 && b 4 == 0x54 && b 5 == 0x45 then some .delete else some .other
  | 0x4F => if len == 7 && b 1 == 0x50 && b 2 == 0x54 && b 3 == 0x49 && b 4 == 0x4F && b 5 == 0x4E && b 6 == 0x53 then some .options else some .other
  | 0x54 => if len == 5 && b 1 == 0x52 && b 2 == 0x41 && b 3 == 0x43 && b 4 == 0x45 then some .trace else some .other
  | 0x43 => if len == 7 && b 1 == 0x4F && b 2 == 0x4E && b 3 == 0x4E && b 4 == 0x45 && b 5 == 0x43 && b 6 == 0x54 then some .connect else some .other
  | _ => some .other

/-- Trim leading/trailing spaces and tabs (OWS) from `[start, stop)`. -/
def trimOWS (buf : ByteArray) (start stop : Nat) : Slice := Id.run do
  let n := buf.size
  let isSp (c : UInt8) : Bool := c == 0x20 || c == 0x09
  let mut i := start
  while i < stop && i < n && isSp (buf.get! i) do i := i + 1
  let mut j := stop
  while start < j && isSp (buf.get! (j - 1)) do j := j - 1
  return { start := i, stop := j }

/-- Parse the request line `METHOD SP target SP HTTP/<major>.<minor>` from `[start, stop)`. -/
def parseRequestLine (buf : ByteArray) (start stop : Nat) : Option (Method × Slice × Slice × Version) := Id.run do
  let mut i := start
  while i < stop && buf.get! i != 0x20 do i := i + 1
  if i >= stop then return none
  let mStop := i
  i := i + 1
  let tStart := i
  while i < stop && buf.get! i != 0x20 do i := i + 1
  if i >= stop then return none
  let tStop := i
  i := i + 1
  let vStart := i
  if stop - vStart < 8 then return none
  if buf.get! vStart != 0x48 || buf.get! (vStart+1) != 0x54 || buf.get! (vStart+2) != 0x54
     || buf.get! (vStart+3) != 0x50 || buf.get! (vStart+4) != 0x2F || buf.get! (vStart+5) != 0x31
     || buf.get! (vStart+6) != 0x2E then return none
  let vb := buf.get! (vStart + 7)
  if vb != 0x31 && vb != 0x30 then return none
  let v := if vb == 0x31 then Version.v11 else Version.v10
  match methodOf buf start mStop with
  | some m => return some (m, { start := start, stop := mStop }, { start := tStart, stop := tStop }, v)
  | none => return none

/-- The result of scanning the header section. -/
inductive HeadersResult where
  | incomplete
  | ok (headers : Array (Slice × Slice)) (rest : Nat)
  | failed (err : HeadError)
deriving Inhabited

/-- Parse the headers and the terminating blank line from `pos`. -/
partial def parseHeaders (buf : ByteArray) (pos count limit : Nat) (acc : Array (Slice × Slice)) : HeadersResult :=
  match findLF buf pos with
  | none => .incomplete
  | some nl =>
    let lineStop := if nl > pos && buf.get! (nl - 1) == 0x0D then nl - 1 else nl
    let next := nl + 1
    if lineStop == pos then
      .ok acc next                                             -- blank line: head complete
    else if count ≥ limit then .failed .headersTooLarge
    else Id.run do
      let mut i := pos
      while i < lineStop && buf.get! i != 0x3A do i := i + 1
      if i >= lineStop then return .failed .badRequest
      let name := { start := pos, stop := i }
      let value := trimOWS buf (i + 1) lineStop
      return parseHeaders buf next (count + 1) limit (acc.push (name, value))

/-- Parse a whole request head from `buf` starting at `pos`. -/
def parseHead (buf : ByteArray) (pos : Nat) (limits : Limits) : HeadResult :=
  match findLF buf pos with
  | none => .incomplete
  | some nl =>
    let lineStop := if nl > pos && buf.get! (nl - 1) == 0x0D then nl - 1 else nl
    let afterLine := nl + 1
    match parseRequestLine buf pos lineStop with
    | none => .failed .badRequest
    | some (method, methodToken, target, version) =>
      match parseHeaders buf afterLine 0 limits.maxHeaders #[] with
      | .incomplete => .incomplete
      | .failed e => .failed e
      | .ok headers bodyStart => .ok { buf, method, methodToken, version, target, headers } bodyStart

/-! ## The connection machine

The driver feeds read bytes in, calls `step` to learn what to write and which events occurred, hands any
`endHeaders` head to the handler, queues the handler's response with `send`/`sendData`/`userClosedBody`, and
stops when `halted` is true. Body framing is `Content-Length` only. -/

/-- The bytes the machine wants the driver to write. -/
structure Output where
  data : Array ByteArray := #[]
deriving Inhabited

namespace Output
/-- Total byte count queued for writing. -/
@[inline] def size (o : Output) : Nat := o.data.foldl (fun a c => a + c.size) 0
end Output

/-- A response head the handler asks the machine to encode. -/
structure ResponseHead where
  status : Nat := 200
  reason : String := "OK"
  headers : Array (String × String) := #[]
deriving Inhabited

/-- What the machine surfaces to the driver after a `step`. -/
inductive Event where
  | endHeaders (head : Head)
  | bodyChunk (data : ByteArray)
  | needMoreData
  | failed (err : HeadError)
deriving Inhabited

/-- The result of a `step`: bytes to write and events to act on. -/
structure StepResult where
  output : Output := {}
  events : Array Event := #[]
deriving Inhabited

/-- Encode a response head as bytes: status line, headers, blank line. -/
def encodeResponseHead (rh : ResponseHead) : ByteArray :=
  let hdrs := String.join (rh.headers.toList.map (fun (n, v) => s!"{n}: {v}\r\n"))
  (s!"HTTP/1.1 {rh.status} {rh.reason}\r\n" ++ hdrs ++ "\r\n").toUTF8

/-- The `Content-Length` value, if present and a plain decimal. -/
def contentLength? (buf : ByteArray) (headers : Array (Slice × Slice)) : Option Nat :=
  let clName := "content-length".toUTF8
  headers.findSome? fun (n, v) =>
    if Slice.eqBytesCI buf n clName then
      Id.run do
        let mut acc := 0
        let mut any := false
        for i in [v.start:v.stop] do
          let c := buf.get! i
          if c ≥ 0x30 && c ≤ 0x39 then
            acc := acc * 10 + (c - 0x30).toNat
            any := true
          else return none
        return if any then some acc else none
    else none

/-- Hex value of one ASCII digit, `none` if it is not one. -/
def hexDigit (c : UInt8) : Option Nat :=
  if c ≥ 0x30 && c ≤ 0x39 then some (c - 0x30).toNat
  else if c ≥ 0x61 && c ≤ 0x66 then some ((c - 0x61).toNat + 10)
  else if c ≥ 0x41 && c ≤ 0x46 then some ((c - 0x41).toNat + 10)
  else none

/-- Parse a chunk-size line `[start, stop)`: hex digits, then optional chunk extensions (`;…`) or OWS. -/
def chunkSize? (buf : ByteArray) (start stop : Nat) : Option Nat := Id.run do
  let mut acc := 0
  let mut any := false
  for i in [start:stop] do
    let c := buf.get! i
    if c == 0x3B then break                                     -- chunk extension: ignore the rest
    match hexDigit c with
    | some d => acc := acc * 16 + d; any := true
    | none => if c == 0x20 || c == 0x09 then break else return none
  return if any then some acc else none

/-- Whether `Transfer-Encoding` makes `chunked` the final coding. -/
def chunked? (head : Head) : Bool :=
  match head.headerValue? "transfer-encoding".toUTF8 with
  | none => false
  | some v =>
    let toks := v.splitOn "," |>.map (fun t => t.trimAscii.toString.toLower) |>.filter (fun t => !t.isEmpty)
    toks.getLast? == some "chunked"

/-- Whether the request asks the server to send `100 Continue` before its body. -/
def expectsContinue (head : Head) : Bool :=
  match head.headerValue? "expect".toUTF8 with
  | none => false
  | some v => (v.splitOn ",").any fun t => t.trimAscii.toString.toLower == "100-continue"

/-- The interim response for `Expect: 100-continue`. -/
def continueBytes : ByteArray := "HTTP/1.1 100 Continue\r\n\r\n".toUTF8

/-- Whether the request asks for the connection to be closed (HTTP/1.0 defaults to close). -/
def wantsClose (buf : ByteArray) (head : Head) : Bool :=
  let connName := "connection".toUTF8
  let conn := head.headers.findSome? fun (n, v) => if Slice.eqBytesCI buf n connName then some v else none
  match conn with
  | some v => if Slice.eqBytesCI buf v "close".toUTF8 then true
              else if Slice.eqBytesCI buf v "keep-alive".toUTF8 then false
              else head.version == Version.v10
  | none => head.version == Version.v10

/-- A connection machine: parse requests, queue responses, decide when to close. -/
structure Machine where
  limits : Limits := {}
  buf : ByteArray := .empty
  pos : Nat := 0
  head? : Option Head := none
  /-- Bytes left in a `Content-Length` body. -/
  bodyRemaining : Nat := 0
  /-- The chunked decoder's position, when the request uses `Transfer-Encoding: chunked`. -/
  chunkState : Option ChunkState := none
  /-- Whether the current request's body has been fully received. True when it has no body. -/
  bodyDone : Bool := true
  /-- The request body accumulated so far, up to `limits.maxBody`. The driver hands it to the handler with the
  head once framing completes (`takeRequest`); this is buffered delivery, not streaming. -/
  reqBody : ByteArray := .empty
  /-- Whether this machine buffers the body and therefore applies `limits.maxBody`. The streaming driver turns
  this off: its body is read incrementally by the handler, so there is no buffered body to bound. -/
  buffered : Bool := true
  out : Array ByteArray := #[]
  keepAlive : Bool := true
  messageCount : Nat := 0
  closing : Bool := false
  halted : Bool := false
  err? : Option HeadError := none
deriving Inhabited

namespace Machine

/-- Append newly read bytes (compacting once the previous request is fully consumed). -/
def feed (m : Machine) (bs : ByteArray) : Machine :=
  if m.pos ≥ m.buf.size then { m with buf := bs, pos := 0 }
  else { m with buf := m.buf ++ bs }

/-- Reject a body that is malformed or exceeds `maxBody`, and stop the connection. -/
def failBody (m : Machine) (e : HeadError) : Machine × StepResult :=
  ({ m with halted := true, err? := some e }, { events := #[.failed e] })

/-- Consume a `Content-Length` body fragment. -/
def stepFixed (m : Machine) : Machine × StepResult :=
  let avail := m.buf.size - m.pos
  if avail == 0 then (m, { events := #[.needMoreData] })
  else
    let n := min avail m.bodyRemaining
    let chunk := m.buf.extract m.pos (m.pos + n)
    let done := n == m.bodyRemaining
    ({ m with pos := m.pos + n, bodyRemaining := m.bodyRemaining - n,
              reqBody := m.reqBody ++ chunk, bodyDone := done },
     { events := #[.bodyChunk chunk] })

/-- Consume a chunked body fragment: size line, data, terminating CRLF, then trailers. Each `step` consumes what
is available and asks for more when it runs out, so a chunk split across reads is decoded in stages. -/
partial def stepChunked (m : Machine) (st : ChunkState) : Machine × StepResult :=
  match st with
  | .sizeLine =>
    match findLF m.buf m.pos with
    | none => (m, { events := #[.needMoreData] })
    | some nl =>
      let lineStop := if nl > m.pos && m.buf.get! (nl - 1) == 0x0D then nl - 1 else nl
      match chunkSize? m.buf m.pos lineStop with
      | none => failBody m .badRequest
      | some 0 => ({ m with pos := nl + 1, chunkState := some .trailers }, {})
      | some n =>
        if m.reqBody.size + n > m.limits.maxBody then failBody m .bodyTooLarge
        else ({ m with pos := nl + 1, chunkState := some (.data n) }, {})
  | .data remaining =>
    let avail := m.buf.size - m.pos
    if avail == 0 then (m, { events := #[.needMoreData] })
    else
      let n := min avail remaining
      let chunk := m.buf.extract m.pos (m.pos + n)
      let st := if n == remaining then .dataCRLF else .data (remaining - n)
      ({ m with pos := m.pos + n, reqBody := m.reqBody ++ chunk, chunkState := some st },
       { events := #[.bodyChunk chunk] })
  | .dataCRLF =>
    let avail := m.buf.size - m.pos
    if avail == 0 then (m, { events := #[.needMoreData] })
    else
      let c0 := m.buf.get! m.pos
      if c0 == 0x0D then
        if avail < 2 then (m, { events := #[.needMoreData] })
        else if m.buf.get! (m.pos + 1) == 0x0A then
          ({ m with pos := m.pos + 2, chunkState := some .sizeLine }, {})
        else failBody m .badRequest
      else if c0 == 0x0A then ({ m with pos := m.pos + 1, chunkState := some .sizeLine }, {})
      else failBody m .badRequest
  | .trailers =>
    match findLF m.buf m.pos with
    | none => (m, { events := #[.needMoreData] })
    | some nl =>
      let lineStop := if nl > m.pos && m.buf.get! (nl - 1) == 0x0D then nl - 1 else nl
      if lineStop == m.pos then
        ({ m with pos := nl + 1, chunkState := some .done, bodyDone := true }, {})
      else ({ m with pos := nl + 1 }, {})                       -- trailer field: consumed, not surfaced
  | .done => ({ m with bodyDone := true }, {})

/-- One step: flush queued output, else finish if halted, else consume the body, else try to parse a head. -/
def step (m : Machine) : Machine × StepResult :=
  if m.out.size > 0 then
    let m' := if m.closing then { m with out := #[], halted := true } else { m with out := #[] }
    (m', { output := { data := m.out } })
  else if m.halted then (m, {})
  else if m.head?.isSome && !m.bodyDone then
    match m.chunkState with
    | some st => stepChunked m st
    | none => stepFixed m
  else
    match parseHead m.buf m.pos m.limits with
    | .incomplete => (m, { events := #[.needMoreData] })
    | .failed e => ({ m with halted := true, err? := some e }, { events := #[.failed e] })
    | .ok head rest =>
      let chunked := chunked? head
      let cl := if chunked then 0 else (contentLength? m.buf head.headers).getD 0
      let count := m.messageCount + 1
      if m.buffered && !chunked && cl > m.limits.maxBody then
        failBody m .bodyTooLarge
      else
        let bodyDone := !chunked && cl == 0
        let interim := if m.limits.autoContinue && expectsContinue head && !bodyDone then
            m.out.push continueBytes else m.out
        ({ m with head? := some head, pos := rest, bodyRemaining := cl, messageCount := count,
                  chunkState := if chunked then some .sizeLine else none, bodyDone,
                  reqBody := .empty, out := interim,
                  keepAlive := !wantsClose m.buf head && count < m.limits.maxMessages },
         { events := #[.endHeaders head] })

/-- Take the request when its framing is complete: the head, its buffered body, and the machine with both
cleared so the next exchange starts fresh. A request with `Content-Length: 0` is complete at its `endHeaders`;
one with a body is complete when `bodyRemaining` reaches zero. -/
def takeRequest (m : Machine) : Head × ByteArray × Machine :=
  ((m.head?.getD default), m.reqBody,
   { m with head? := none, reqBody := .empty, bodyRemaining := 0, chunkState := none, bodyDone := true })

/-- Queue an encoded response head. The `Connection` directive on the wire is the machine's own disposition,
reconciled with the handler's: a handler's `Connection: close` is honoured -- recorded here, so `userClosedBody`
ends the connection -- and a handler's `Connection: keep-alive` cannot keep a connection the machine must close
(the peer asked to close, or `maxMessages` was reached). Exactly one directive goes out: `close` when the
machine will close, nothing otherwise, since keep-alive is the HTTP/1.1 default. A close the machine is about
to make is the peer's to know about: undisclosed, it reads as a truncated connection, not an ended exchange. -/
def send (m : Machine) (rh : ResponseHead) : Machine :=
  let handlerClose := rh.headers.any (fun (n, v) =>
    n.toLower == "connection" && (v.splitOn ",").any (fun t => t.trimAscii.toString.toLower == "close"))
  let m := if handlerClose then { m with keepAlive := false } else m
  let rh := { rh with headers := rh.headers.filter (fun (n, _) => n.toLower != "connection") }
  let rh := if m.keepAlive then rh else { rh with headers := #[("Connection", "close")] ++ rh.headers }
  { m with out := m.out.push (encodeResponseHead rh) }

/-- Put an error response on the wire (`Connection: close`, empty body) and stop accepting input. The machine
halts once those bytes have been flushed, not before, so the answer is not dropped. -/
def closeWithError (m : Machine) (status : Nat) (reason : String := "Internal Server Error") : Machine :=
  { m with
    out := m.out.push (encodeResponseHead
      { status, reason, headers := #[("Connection", "close"), ("Content-Length", "0")] }),
    closing := true }

/-- Queue body bytes. -/
def sendData (m : Machine) (chunks : Array ByteArray) : Machine :=
  { m with out := m.out ++ chunks }

/-- The handler has finished the body: keep the connection alive, or close it -- the close halts once the
queued answer has been flushed, not before, so the answer is not dropped. -/
def userClosedBody (m : Machine) : Machine :=
  if m.keepAlive then { m with head? := none, bodyRemaining := 0, chunkState := none, bodyDone := true }
  else if m.out.size > 0 then { m with closing := true }
  else { m with halted := true }

/-- The peer has sent all it will: close if nothing is mid-flight -- an answer still queued to be written is
mid-flight, so the close halts once it has been flushed, not before. -/
def noMoreInput (m : Machine) : Machine :=
  if m.head?.isNone && m.pos ≥ m.buf.size then
    if m.out.size > 0 then { m with closing := true } else { m with halted := true }
  else m

end Machine

end H1
end Http
end LeanIn
end
