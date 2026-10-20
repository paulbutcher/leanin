import LeanIn
import LeanIn.Examples.Http.H1
import LeanIn.Examples.Http.Server
import LeanIO.Router.RouteTrie
import Std.Http.Data.Method
import Lean
import LeanIO.Data.Headers.MimeType
import LeanIO.Request.FromRequestBody
import LeanIO.Request.Form

/-!
# The LeanIn backend

Routes stored over a LeanIn handler value (`RouteTrie Handler`) and dispatched on a LeanIn connection. A
handler sees a `Request`: the parsed head, the buffered body, and the path parameters the trie captured when
the route has parameters. Middleware is a handler transformer, composed before insertion, as in the upstream
trie.

The application-facing effect signature and the reasoning obligations are
`docs/notes/LeanIO_to_LeanIn_Effect_Signature.md`. Bodies are buffered (bounded by `H1.Limits.maxBody`);
streaming, multipart and the request scope are later stages of
`docs/notes/LeanIO_to_LeanIn_Porting_Handoff.md`.
-/

namespace LeanIO.Backend.LeanIn

open LeanIn
open LeanIn.Examples.Http
open LeanIO.Router
open Std.Http

/-- The driver's handler: the shape `serveConn` runs. -/
abbrev CoreHandler := LeanIn.Examples.Http.Server.Handler

/-- A request as the native backend sees it. `params` are the trie's captures for a parameterised route, in
the order the pattern names them. -/
structure Request where
  head : H1.Head
  body : ByteArray := .empty
  params : List (String × String) := []

/-- A native handler: request in, buffered response out. -/
abbrev Handler := Request → LeanIn.Runtime.VM (H1.ResponseHead × ByteArray)

/-- Middleware transforms a handler; composition order is nesting order (the leftmost/outermost runs first). -/
abbrev Middleware := Handler → Handler

/-- The method token as `Std.Http.Method`, or `none` when the token is not one it names. Unknown methods are
refused explicitly at dispatch; they are never mapped onto a different method. -/
def method? (h : H1.Head) : Option Std.Http.Method :=
  Std.Http.Method.ofString? h.methodTokenString

/-- Percent-decode `s`; `+` becomes a space when `plusIsSpace`, and stays literal in a path. -/
def pctDecode (s : String) (plusIsSpace : Bool) : String := Id.run do
  let bs := s.toUTF8
  let hex (c : UInt8) : Option Nat :=
    if c ≥ 0x30 && c ≤ 0x39 then some (c - 0x30).toNat
    else if c ≥ 0x61 && c ≤ 0x66 then some (c - 0x61 + 10).toNat
    else if c ≥ 0x41 && c ≤ 0x46 then some (c - 0x41 + 10).toNat
    else none
  let mut out := ByteArray.empty
  let mut i := 0
  while i < bs.size do
    let c := bs.get! i
    if c == 0x25 && i + 2 < bs.size then
      match hex (bs.get! (i + 1)), hex (bs.get! (i + 2)) with
      | some hi, some lo => out := out.push (hi * 16 + lo).toUInt8; i := i + 3
      | _, _ => out := out.push c; i := i + 1
    else if plusIsSpace && c == 0x2B then
      out := out.push 0x20; i := i + 1
    else
      out := out.push c; i := i + 1
  return (String.fromUTF8? out).getD s

/-- The request target without its query. -/
def Request.path (r : Request) : String :=
  let t := r.head.targetString
  (t.splitOn "?").headD t

/-- The path segments, query removed and each percent-decoded. -/
def pathSegments (h : H1.Head) : List String :=
  let t := h.targetString
  let path := (t.splitOn "?").headD t
  (path.splitOn "/").filter (fun s => !s.isEmpty) |>.map (fun s => pctDecode s false)

/-- The raw query string (after `?` and before `#`), if any. -/
def Request.queryString? (r : Request) : Option String :=
  match r.head.targetString.splitOn "?" with
  | _ :: q :: _ => some ((q.splitOn "#").headD q)
  | _ => none

/-- The query parameters, decoded by LeanIO's query parser. Only `none` when the query is malformed. -/
def Request.query? (r : Request) : Option Std.Http.URI.Query :=
  match r.queryString? with
  | none => some {}
  | some q =>
    match LeanIO.parseQuery {} q.toUTF8.iter with
    | .success _ query => some query
    | .error _ _ => none

/-- A captured path parameter by name. -/
def Request.pathParam? (r : Request) (name : String) : Option String :=
  r.params.find? (·.1 == name) |>.map (·.2)

/-- The first header value with this name, as text. -/
def Request.header? (r : Request) (name : String) : Option String :=
  H1.Head.headerValue? r.head name.toUTF8

/-- The media type of `Content-Type`, lowercased and without parameters. -/
def Request.mediaType? (r : Request) : Option String :=
  (r.header? "content-type").map fun v =>
    (v.splitOn ";" |>.headD v).trimAscii.toString.toLower

/-- Whether the request's media type matches one the extractor type names. A request with no `Content-Type`
does not match a type declaring media types: accepting it silently would make a JSON route answer to
form-encoded or absent bodies. -/
def Request.mimeOk (r : Request) (t : Type) [LeanIO.MimeType.HasMimeTypes t] : Bool :=
  match LeanIO.MimeType.HasMimeTypes.mimes? t with
  | none => true
  | some mimes =>
    match r.mediaType? with
    | none => false
    | some actual => mimes.any fun m => m.value.toLower == actual

/-- Decode a JSON body. The failures are distinguishable: 415 for the wrong media type, 400 for malformed
JSON, 422 when it parses but does not fit `α`. -/
def jsonBody (α : Type) [Lean.FromJson α] [LeanIO.MimeType.HasMimeTypes (LeanIO.Json α)] (r : Request) :
    Except (Nat × String) α :=
  if !r.mimeOk (LeanIO.Json α) then
    .error (415, "unsupported media type")
  else
    match String.fromUTF8? r.body with
    | none => .error (400, "body is not valid UTF-8")
    | some text =>
      match Lean.Json.parse text with
      | .error e => .error (400, s!"malformed JSON: {e}")
      | .ok j =>
        match Lean.FromJson.fromJson? (α := α) j with
        | .ok a => .ok a
        | .error e => .error (422, s!"body does not fit: {e}")

/-- A plain-text body, with the same media-type check. -/
def textBody (r : Request) : Except (Nat × String) String :=
  if !r.mimeOk LeanIO.PlainText then
    .error (415, "unsupported media type")
  else
    match String.fromUTF8? r.body with
    | none => .error (400, "body is not valid UTF-8")
    | some text => .ok text

/-- Decode an `application/x-www-form-urlencoded` body. The query parser and `FromForm` are LeanIO's; only the
transport (buffered bytes instead of a stock body stream) is the backend's. -/
def formBody (α : Type) [LeanIO.FromForm α] [LeanIO.MimeType.HasMimeTypes (LeanIO.Form α)] (r : Request) :
    Except (Nat × String) α :=
  if !r.mimeOk (LeanIO.Form α) then
    .error (415, "unsupported media type")
  else
    match LeanIO.parseQuery {} r.body.iter with
    | .success _ query =>
      match LeanIO.FromForm.fromForm (α := α) query with
      | .ok v => .ok v
      | .error e => .error (422, s!"body does not fit: {e}")
    | .error _ _ => .error (400, "malformed form body")

/-- A response with one buffered body and a `Content-Length`. -/
def response (status : Nat) (reason : String) (body : ByteArray)
    (headers : Array (String × String) := #[]) : H1.ResponseHead × ByteArray :=
  ({ status, reason, headers := headers.push ("Content-Length", toString body.size) }, body)

/-- Dispatch a parsed head through the trie.

An unknown method token is refused with 501 rather than dispatched. A path known under other methods answers 405
with `Allow`; a miss goes to the trie's `notFound` handler or a 404. The trie's captured parameters become the
request's `params`. -/
def dispatch (trie : RouteTrie Handler) : CoreHandler := fun head body =>
  match method? head with
  | none => pure (response 501 "Not Implemented" "method not supported\n".toUTF8)
  | some m =>
    match trie.lookup m (pathSegments head) with
    | .found params handler => handler { head, body, params }
    | .methodMismatch allowed =>
      pure (response 405 "Method Not Allowed" "".toUTF8 #[("Allow", RouteTrie.allowValue allowed)])
    | .noMatch =>
      match trie.notFound with
      | some handler => handler { head, body }
      | none => pure (response 404 "Not Found" "not found\n".toUTF8)

/-- Serve `handler` on `port` with the given hooks (so an application can build handlers against the same live
clock, e.g. to suspend on a timer). Blocks until the accept loop ends. -/
def serveWith (hooks : LeanIn.Runtime.Hooks) (handler : CoreHandler) (port : UInt16) : IO UInt32 := do
  let l ← LeanIn.Runtime.Listener.bind (LeanIn.Runtime.loopback port)
  let e ← LeanIn.Sched.Executor.new LeanIn.Task.Item 256 1
  let cfg : LeanIn.Examples.Http.Server.Config := { clock := LeanIn.Runtime.Clock.live hooks }
  let prog : LeanIn.Task.EAsync IO.Error Unit :=
    LeanIn.Runtime.serveForever hooks l (LeanIn.Examples.Http.Server.serveConn cfg · handler)
  let outcome : Except IO.Error Unit ← LeanIn.Runtime.run e prog
  LeanIn.Runtime.Io.stop
  match outcome with
  | .ok _ => return 0
  | .error err => IO.eprintln s!"the accept loop ended: {err}"; return 1

/-- Serve `handler` on `port`, creating the hooks. -/
def serve (handler : CoreHandler) (port : UInt16) : IO UInt32 := do
  let hooks ← LeanIn.Runtime.Hooks.new
  serveWith hooks handler port

end LeanIO.Backend.LeanIn
