module

public import LeanIn
public import LeanIn.Examples.Http.H1
public import LeanIn.Examples.Http.Server
public import LeanIO.Router.RouteTrie
public import Std.Http.Data.Method
public import Lean
public import LeanIO.Data.Headers.MimeType
public import LeanIO.Request.FromRequestBody
public import LeanIO.Request.FromRequestParts
public import LeanIO.Request.MultiPartForm.Api
public import LeanIO.Request.Form

public section

/-!
# The LeanIn backend

Routes stored over a LeanIn handler value (`RouteTrie Handler`) and dispatched on a LeanIn connection. A
handler sees a `Request`: the parsed head, the streaming body reader, and the path parameters the trie captured
when the route has parameters. Middleware is a handler transformer, composed before insertion, as in the
upstream trie.

The application-facing effect signature and the reasoning obligations are
`docs/notes/LeanIO_to_LeanIn_Effect_Signature.md`. The streaming body reader and response writer are
implemented. A buffered extractor accumulates the whole body through `readAll`, and on this streaming path that
accumulation is **not bounded by `H1.Limits.maxBody`**: `readAll` keeps appending as bytes arrive, so it may grow
with the input. The `maxBody` bound belongs to the separate buffered driver, which rejects an oversize
`Content-Length` body with 413 before dispatch. A request's own transport failure is the **peer-I/O request
scope**: a failed read, a stall, a peer close mid-body or a failed response send is a typed VM abort that the
streaming driver's scope turns into a closed connection, never a catchable error (`docs/decisions.md` D23).
Still later stages of `docs/notes/LeanIO_to_LeanIn_Porting_Handoff.md`: child/task cancellation, shutdown/drain
and scope-exit cleanup.
-/

namespace LeanIO.Backend.LeanIn

open LeanIn
open LeanIn.Examples.Http
open LeanIO.Router
open Std.Http

/-- The driver's handler: the streaming session shape. -/
abbrev CoreHandler := LeanIn.Examples.Http.Server.StreamHandler

/-- A request as the native backend sees it. `body` is the streaming reader; an extractor that needs the
whole body reads it, and a route that streams consumes it incrementally. `params` are the trie's captures for
a parameterised route, in the order the pattern names them. -/
structure Request where
  head : H1.Head
  body : LeanIn.Examples.Http.Server.BodyReader
  params : List (String × String) := []

/-- A native handler: the request and the response writer, so a response need not be accumulated. -/
abbrev Handler := Request → LeanIn.Examples.Http.Server.ResponseWriter → LeanIn.Runtime.VM Unit

/-- Read a whole body through the reader. This is what a buffered extractor (`jsonBody`, `formBody`) does; a
streaming route calls `recv` itself and never accumulates. -/
partial def readAll (r : LeanIn.Examples.Http.Server.BodyReader) (acc : ByteArray) : LeanIn.Runtime.VM ByteArray := do
  match ← r.recv 65536 with
  | some chunk => readAll r (acc ++ chunk)
  | none => return acc

/-- Middleware transforms a handler; composition order is nesting order (the leftmost/outermost runs first). -/
abbrev Middleware := Handler → Handler

/-- Applies middlewares the way the upstream router does: a left fold, so the **last** one added runs first
(outermost). -/
def applyMiddlewares (ms : Array Middleware) : Middleware :=
  ms.foldl (fun h mw => mw h)

/-- One declared route: method, pattern, handler and its own middlewares (innermost). -/
structure NativeRoute where
  method : Std.Http.Method
  pattern : RoutePattern
  handler : Handler
  middlewares : Array Middleware := #[]

/-- A router with the upstream composition semantics: route middlewares innermost, then the router's, mounts
prefixed, and a `notFound` for misses. `toTrie` compiles it once, as upstream does at startup. -/
structure NativeRouter where
  routes : Array NativeRoute := #[]
  mounts : Array (String × NativeRouter) := #[]
  middlewares : Array Middleware := #[]
  notFound : Option Handler := none

namespace NativeRouter

def empty : NativeRouter := {}

/-- Add a route value, as built by `nativeRoute`. -/
def add (self : NativeRouter) (r : NativeRoute) : NativeRouter :=
  { self with routes := self.routes.push r }

/-- Add a route from a pattern string such as `/user/{id}`. -/
def route (self : NativeRouter) (method : Std.Http.Method) (pattern : String) (handler : Handler) :
    NativeRouter :=
  let r : NativeRoute := { method, pattern := RoutePattern.ofString pattern, handler }
  { self with routes := self.routes.push r }

/-- Add a route with its own middlewares; they run inside the router's. -/
def routeWith (self : NativeRouter) (method : Std.Http.Method) (pattern : String) (handler : Handler)
    (middlewares : Array Middleware) : NativeRouter :=
  let r : NativeRoute := { method, pattern := RoutePattern.ofString pattern, handler, middlewares }
  { self with routes := self.routes.push r }

/-- Append a router middleware. With the fold in `applyMiddlewares`, the last added runs first. -/
def addMiddleware (mw : Middleware) (self : NativeRouter) : NativeRouter :=
  { self with middlewares := self.middlewares.push mw }

/-- Mount a sub-router under a prefix. -/
def mount (self : NativeRouter) (pre : String) (sub : NativeRouter) : NativeRouter :=
  { self with mounts := self.mounts.push (pre, sub) }

/-- The handler for requests matching no route. -/
def withNotFound (handler : Handler) (self : NativeRouter) : NativeRouter :=
  { self with notFound := some handler }

/-- Compile the router into a trie, composing middlewares once. -/
partial def toTrie (self : NativeRouter) : RouteTrie Handler :=
  let wrap := applyMiddlewares self.middlewares
  let trie := self.routes.foldl (fun acc r =>
    acc.addRoute r.method r.pattern.segments (wrap (applyMiddlewares r.middlewares r.handler)))
    (RouteTrie.empty : RouteTrie Handler)
  let trie := self.mounts.foldl (fun acc (pre, sub) =>
    let preSegs := (RoutePattern.ofString pre).segments
    RouteTrie.fold sub.toTrie (fun method segs handler acc =>
      acc.addRoute method (preSegs ++ segs) (wrap handler)) acc) trie
  { trie with notFound := self.notFound.map wrap }

end NativeRouter

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

/-- A query parameter by name, decoded; `none` when absent, undecodable, or the query is malformed. -/
def Request.queryParam? (r : Request) (name : String) : Option String :=
  match r.query? with
  | none => none
  | some q =>
    let pairs : Array (Std.Http.URI.EncodedQueryParam × Option Std.Http.URI.EncodedQueryParam) := q
    let found : Option (Std.Http.URI.EncodedQueryParam × Option Std.Http.URI.EncodedQueryParam) :=
      pairs.find? (fun p => p.1.decode == some name)
    found.bind (fun p => p.2.bind (fun v => v.decode))

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
    LeanIn.Runtime.VM (Except (Nat × String) α) := do
  if !r.mimeOk (LeanIO.Json α) then
    return .error (415, "unsupported media type")
  else
    let b ← readAll r.body .empty
    return (match String.fromUTF8? b with
    | none => .error (400, "body is not valid UTF-8")
    | some text =>
      match Lean.Json.parse text with
      | .error e => .error (400, s!"malformed JSON: {e}")
      | .ok j =>
        match Lean.FromJson.fromJson? (α := α) j with
        | .ok a => .ok a
        | .error e => .error (422, s!"body does not fit: {e}"))

/-- A plain-text body, with the same media-type check. -/
def textBody (r : Request) : LeanIn.Runtime.VM (Except (Nat × String) String) := do
  if !r.mimeOk LeanIO.PlainText then
    return .error (415, "unsupported media type")
  else
    let b ← readAll r.body .empty
    return (match String.fromUTF8? b with
    | none => .error (400, "body is not valid UTF-8")
    | some text => .ok text)

/-- Decode an `application/x-www-form-urlencoded` body. The query parser and `FromForm` are LeanIO's; only the
transport (buffered bytes instead of a stock body stream) is the backend's. -/
def formBody (α : Type) [LeanIO.FromForm α] [LeanIO.MimeType.HasMimeTypes (LeanIO.Form α)] (r : Request) :
    LeanIn.Runtime.VM (Except (Nat × String) α) := do
  if !r.mimeOk (LeanIO.Form α) then
    return .error (415, "unsupported media type")
  else
    let b ← readAll r.body .empty
    return (match LeanIO.parseQuery {} b.iter with
    | .success _ query =>
      match LeanIO.FromForm.fromForm (α := α) query with
      | .ok v => .ok v
      | .error e => .error (422, s!"body does not fit: {e}")
    | .error _ _ => .error (400, "malformed form body"))

/-- The reason phrase the backend uses for its own statuses. -/
def reasonFor : Nat → String
  | 400 => "Bad Request"
  | 401 => "Unauthorized"
  | 403 => "Forbidden"
  | 404 => "Not Found"
  | 405 => "Method Not Allowed"
  | 413 => "Payload Too Large"
  | 415 => "Unsupported Media Type"
  | 422 => "Unprocessable Entity"
  | 431 => "Request Header Fields Too Large"
  | 501 => "Not Implemented"
  | _   => "Internal Server Error"

/-- Strip one pair of surrounding double quotes. -/
def unquote (s : String) : String :=
  if s.length ≥ 2 && s.startsWith "\"" && s.endsWith "\"" then
    (s.drop 1).dropEnd 1 |>.toString
  else s

/-- The `boundary` parameter of a `multipart/form-data` content type. -/
def boundary? (r : Request) : Option String :=
  (r.header? "content-type").bind fun v =>
    (v.splitOn ";").findSome? fun p =>
      match p.trimAscii.toString.splitOn "=" with
      | ["boundary", b] => some (unquote (b.trimAscii.toString))
      | _ => none

/-- The native body source for the upstream multipart parser. -/
instance : LeanIO.BodySource LeanIn.Runtime.VM LeanIn.Examples.Http.Server.BodyReader where
  recv r := r.recv 65536

/-- Build the upstream `MultiPartForm` over the native request reader. -/
def multipartForm (req : Request) :
    LeanIn.Runtime.VM (Except (Nat × String)
      (LeanIO.MultiPartForm LeanIn.Runtime.VM LeanIn.Examples.Http.Server.BodyReader)) := do
  if req.mediaType? != some "multipart/form-data" then
    return .error (415, "unsupported media type")
  match boundary? req with
  | none => return .error (400, "missing multipart boundary")
  | some b =>
    let boundSep := ("\r\n--" ++ b).toUTF8
    let inner : LeanIO.MultipartInner LeanIn.Runtime.VM LeanIn.Examples.Http.Server.BodyReader := {
      boundStart := boundSep.extract 2 boundSep.size
      boundSepSearch := LeanIO.Search.new (LeanIO.ChunkBuffer.ofByteArray boundSep)
      stream := req.body }
    let ref ← (monadLift (IO.mkRef inner) : LeanIn.Runtime.VM _)
    return .ok { inner := ref }

/-- Compose the upstream multipart API with a handler. The entries and `FormFile` operations are the same
types the stock backend uses, instantiated at `VM`/`BodyReader`. -/
def withMultipartForm
    (f : LeanIO.MultiPartForm LeanIn.Runtime.VM LeanIn.Examples.Http.Server.BodyReader → Handler) :
    Handler :=
  fun req w => do
    match ← multipartForm req with
    | .ok mp => f mp req w
    | .error (status, msg) =>
      w.start { status, reason := reasonFor status,
                headers := #[("Content-Length", toString msg.toUTF8.size)] }
      w.write msg.toUTF8
      w.finish

/-- A response with one buffered body and a `Content-Length`. -/
def response (status : Nat) (reason : String) (body : ByteArray)
    (headers : Array (String × String) := #[]) : H1.ResponseHead × ByteArray :=
  ({ status, reason, headers := headers.push ("Content-Length", toString body.size) }, body)

/-- A buffered response through the streaming writer: `Content-Length` and one write. -/
def respond (w : LeanIn.Examples.Http.Server.ResponseWriter) (status : Nat) (reason : String)
    (body : ByteArray) (headers : Array (String × String) := #[]) : LeanIn.Runtime.VM Unit := do
  w.start { status, reason, headers := headers.push ("Content-Length", toString body.size) }
  w.write body
  w.finish

/-- The application environment a route body sees under the parameterised syntax: the request and the response
writer, so a body can read and write without receiving them as arguments. -/
structure Env where
  req : Request
  writer : LeanIn.Examples.Http.Server.ResponseWriter

/-- The native application monad. A body written in the route syntax runs in `AppM`; the handler supplies the
environment once. -/
abbrev AppM := ReaderT Env LeanIn.Runtime.VM

namespace AppM

/-- The request being handled. -/
def request : AppM Request := fun env => pure env.req

/-- Send a buffered response: head with `Content-Length`, one write, finish. -/
def respond (status : Nat) (reason : String) (body : ByteArray)
    (headers : Array (String × String) := #[]) : AppM Unit :=
  fun env => LeanIO.Backend.LeanIn.respond env.writer status reason body headers

/-- The response writer, for a body that streams. -/
def writer : AppM LeanIn.Examples.Http.Server.ResponseWriter := fun env => pure env.writer

/-- The request body reader, for a route that streams the request. -/
def bodyReader : AppM LeanIn.Examples.Http.Server.BodyReader := fun env => pure env.req.body

end AppM

/-- A request-body extraction in the native application monad. The failure is the status and message to answer
with, as in the buffered extractors. -/
class FromRequestBodyM (α : Type) where
  read : Env → LeanIn.Runtime.VM (Except (Nat × String) α)

/-- JSON bodies in the native monad. -/
instance [Lean.FromJson α] [LeanIO.MimeType.HasMimeTypes (LeanIO.Json α)] : FromRequestBodyM (LeanIO.Json α) where
  read env := do
    match ← jsonBody α env.req with
    | .ok a => pure (.ok { body := a })
    | .error e => pure (.error e)

/-- Plain-text bodies in the native monad. -/
instance : FromRequestBodyM LeanIO.PlainText where
  read env := do
    match ← textBody env.req with
    | .ok text => pure (.ok { body := text })
    | .error e => pure (.error e)

/-- A form-encoded body in the native monad. -/
instance [LeanIO.FromForm α] [LeanIO.MimeType.HasMimeTypes (LeanIO.Form α)] :
    FromRequestBodyM (LeanIO.Form α) where
  read env := do
    match ← LeanIO.Backend.LeanIn.formBody α env.req with
    | .ok a => pure (.ok { value := a })
    | .error e => pure (.error e)

/-- The raw body bytes in the native monad. -/
instance : FromRequestBodyM ByteArray where
  read env := do
    return .ok (← readAll env.req.body .empty)

/-- A request-parts extraction in the native backend. As in the stock classes, a failure is the status and
message to answer with. -/
class FromRequestPartsM (α : Type) where
  readParts : Request → Except (Nat × String) α

/-- `Path α` from a named path-parameter map (`FromPath`). -/
instance [LeanIO.FromPath α] : FromRequestPartsM (LeanIO.Path α) where
  readParts r :=
    match LeanIO.FromPath.fromPath (Std.HashMap.ofList r.params) with
    | .ok v => .ok { value := v }
    | .error e => .error (400, e)

/-- `Path α` from the single captured parameter (`FromString`). -/
instance [LeanIO.FromString α] : FromRequestPartsM (LeanIO.Path α) where
  readParts r :=
    if r.params.length != 1 then
      .error (400, "expected exactly one path parameter")
    else
      match LeanIO.FromString.parse r.params[0]!.2 with
      | .ok v => .ok { value := v }
      | .error e => .error (400, e)

/-- The request's query (`Std.Http.URI.Query`), or 400 when it is malformed. -/
instance : FromRequestPartsM Std.Http.URI.Query where
  readParts r :=
    match r.query? with
    | some q => .ok q
    | none => .error (400, "malformed query")

/-- The binders after a body extractor: a body that is already in `AppM`. -/
class NativePartsExtractor (Fn : Type) where
  extractParts : Fn → Handler

/-- Adapt a route body's binders to a native handler, mirroring `LeanIO.Extractor` for the stock backend. -/
class NativeExtractor (Fn : Type) where
  extract : Fn → Handler

instance : NativePartsExtractor (AppM Unit) where
  extractParts f req w := f { req, writer := w }

instance [FromRequestBodyM P] [NativePartsExtractor Rest] : NativeExtractor (P → Rest) where
  extract f req w := do
    match ← FromRequestBodyM.read (α := P) { req, writer := w } with
    | .ok p => NativePartsExtractor.extractParts (f p) req w
    | .error (status, msg) => LeanIO.Backend.LeanIn.respond w status (reasonFor status) msg.toUTF8

instance [FromRequestPartsM P] [NativePartsExtractor Rest] : NativeExtractor (P → Rest) where
  extract f req w := do
    match FromRequestPartsM.readParts (α := P) req with
    | .ok p => NativePartsExtractor.extractParts (f p) req w
    | .error (status, msg) => LeanIO.Backend.LeanIn.respond w status (reasonFor status) msg.toUTF8

instance [FromRequestPartsM P] [NativePartsExtractor Rest] : NativePartsExtractor (P → Rest) where
  extractParts f req w := do
    match FromRequestPartsM.readParts (α := P) req with
    | .ok p => NativePartsExtractor.extractParts (f p) req w
    | .error (status, msg) => LeanIO.Backend.LeanIn.respond w status (reasonFor status) msg.toUTF8

instance : NativeExtractor (Unit → AppM Unit) where
  extract f req w := f () { req, writer := w }

instance : NativeExtractor (AppM Unit) where
  extract f req w := f { req, writer := w }

/-- Error scope as a handler: `VM.attempt` carries the catch through every suspension, so a handler that
parks and then raises is caught here exactly as one that raises at once. The failure becomes a 500 carrying the
error's `toString`, rather than escaping the connection.

A transport failure never arrives here: inside the streaming request scope the body reader and the response
writer classify it on the VM's separate abort channel, which `attempt` does not catch, so no further response is
attempted for a cancelled request instead of a 500. The driver's own raw operations outside that scope are not VM
effects at all: a failed send or read prompts a close attempt and reports the transport error, while a refused
close is reported as its own error and does not establish that the connection closed. Only an
ordinary raise — including one whose message happens to begin `Http:` — is this middleware's. -/
def catchErrors : Middleware :=
  fun handler req w => do
    match ← LeanIn.Runtime.VM.attempt (handler req w) with
    | .ok _ => pure ()
    | .error e =>
      monadLift (IO.eprintln s!"leanio: 500: {e}")
      respond w 500 "Internal Server Error" (toString e).toUTF8

/-- Observing middleware: logs method, path and status through `IO` lifted into the machine, then returns the
response unchanged. -/
def requestLogger (label : String) : Middleware :=
  fun handler req w => do
    handler req w
    let code ← w.code
    let line := label ++ " " ++ req.head.methodTokenString ++ " " ++ req.path ++ " -> " ++ toString (code.getD 0)
    monadLift (do IO.println line; IO.getStdout >>= fun s => s.flush)

/-- Compose an extractor with a handler: an extraction failure becomes the response, so applications compose
`withExtract (jsonBody T) fun t => …` the way the stock extractor classes compose. -/
def withExtract (extract : Request → LeanIn.Runtime.VM (Except (Nat × String) α)) (f : α → Handler) :
    Handler :=
  fun req w => do
    match ← extract req with
    | .ok a => f a req w
    | .error (status, msg) => respond w status (reasonFor status) msg.toUTF8

/-- A writer that runs the handler but drops the body, for HEAD from a GET route. -/
def discardBody (w : LeanIn.Examples.Http.Server.ResponseWriter) :
    LeanIn.Examples.Http.Server.ResponseWriter := {
  start := fun rh =>
    let hs := (rh.headers.filter (fun (n, _) => n.toLower != "content-length")).push ("Content-Length", "0")
    w.start { rh with headers := hs }
  write := fun _ => pure ()
  finish := w.finish
  status := w.status
  code := w.code }

/-- Dispatch a parsed head and streaming body through the trie.

An unknown method token is refused with 501 rather than dispatched. A path known under other methods answers 405
with `Allow`; a miss goes to the trie's `notFound` handler or a 404. The trie's captured parameters become the
request's `params`. -/
def dispatch (trie : RouteTrie Handler) : CoreHandler := fun head body w =>
  match method? head with
  | none => respond w 501 "Not Implemented" "method not supported\n".toUTF8
  | some m =>
    match trie.lookup m (pathSegments head) with
    | .found params handler => handler { head, body, params } w
    | .methodMismatch allowed =>
      -- LeanIO serves HEAD from the GET handler and drops the body; the response declares
      -- `Content-Length: 0` rather than the length the body would have had, because declaring a length it
      -- will not send would strand the client. This matches the upstream trie's documented behaviour.
      if m == .head && allowed.contains .get then
        match trie.lookup .get (pathSegments head) with
        | .found params handler => handler { head, body, params } (discardBody w)
        | _ => respond w 405 "Method Not Allowed" "".toUTF8 #[("Allow", RouteTrie.allowValue allowed)]
      else
        respond w 405 "Method Not Allowed" "".toUTF8 #[("Allow", RouteTrie.allowValue allowed)]
    | .noMatch =>
      match trie.notFound with
      | some handler => handler { head, body } w
      | none => respond w 404 "Not Found" "not found\n".toUTF8

/-- Serve `handler` on `port` with the given hooks (so an application can build handlers against the same live
clock, e.g. to suspend on a timer). Blocks until the accept loop ends. -/
def serveWith (hooks : LeanIn.Runtime.Hooks) (handler : CoreHandler) (port : UInt16) : IO UInt32 := do
  let l ← LeanIn.Runtime.Listener.bind (LeanIn.Runtime.loopback port)
  let e ← LeanIn.Sched.Executor.new LeanIn.Task.Item 256 1
  let cfg : LeanIn.Examples.Http.Server.Config := { clock := LeanIn.Runtime.Clock.live hooks }
  let prog : LeanIn.Task.EAsync IO.Error Unit :=
    LeanIn.Runtime.serveForever hooks l (LeanIn.Examples.Http.Server.serveConnStream cfg · handler)
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
end
