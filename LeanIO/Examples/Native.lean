import LeanIO.Router.Macro
import LeanIO.Backend.LeanIn

/-!
# `leanioNative` — the first native LeanIn-backed LeanIO server

Two routes over the generic route trie, dispatched by `LeanIO.Backend.LeanIn` on a LeanIn connection:

- `GET /ping` answers immediately;
- `GET /slow` parks in `VM.sleep` for 200 ms before answering, so a sibling request can complete while it is
  suspended.

This is the port's first milestone: routing and dispatch are LeanIO's (the trie is the upstream one, parameterised
over its handler value), the connection, handler execution and clock are LeanIn's, and no stock `Async`,
`ContextAsync` or `Std.Http.Server` is on the serving path.
-/

open LeanIn
open LeanIO.Router
open LeanIO.Backend

abbrev Handler := LeanIO.Backend.LeanIn.Handler
abbrev Middleware := LeanIO.Backend.LeanIn.Middleware

namespace LeanIO.Examples.Native

open LeanIn.Examples.Http

def ping : Handler :=
  fun _ w => LeanIO.Backend.LeanIn.respond w 200 "OK" "pong\n".toUTF8

def slow (clock : LeanIn.Runtime.Clock) : Handler :=
  fun _ w => do
    let _ ← LeanIn.Runtime.VM.sleep clock 200
    LeanIO.Backend.LeanIn.respond w 200 "OK" "slept\n".toUTF8

/-- A JSON body type: the first extraction shown over the native request pair. -/
structure Todo where
  title : String
  done : Bool := false
deriving Lean.FromJson, Lean.ToJson, Repr

def reasonFor : Nat → String
  | 413 => "Payload Too Large"
  | 415 => "Unsupported Media Type"
  | 422 => "Unprocessable Entity"
  | _   => "Bad Request"

/-- JSON extraction: 415 for the wrong media type, 400 for malformed JSON, 422 when it does not fit. -/
def postTodo : Handler :=
  LeanIO.Backend.LeanIn.withExtract (LeanIO.Backend.LeanIn.jsonBody Todo) fun todo _req w =>
    LeanIO.Backend.LeanIn.respond w 200 "OK" (Lean.toJson todo).compress.toUTF8

/-- Plain-text extraction with the same media-type contract. -/
def postText : Handler :=
  LeanIO.Backend.LeanIn.withExtract LeanIO.Backend.LeanIn.textBody fun text _req w =>
    LeanIO.Backend.LeanIn.respond w 200 "OK" s!"text: {text}\n".toUTF8

/-- Path parameters captured by the trie (`/user/{id}`), plus a query parameter. -/
def userById : Handler :=
  fun req w =>
    let id := (req.pathParam? "id").getD ""
    let name := (req.queryParam? "name").getD ""
    LeanIO.Backend.LeanIn.respond w 200 "OK" s!"id={id} name={name}\n".toUTF8

/-- Raises *after* a suspension, to exercise an error scope across a park. -/
def boom (clock : LeanIn.Runtime.Clock) : Handler :=
  fun _ _ => do
    let _ ← LeanIn.Runtime.VM.sleep clock 100
    throw (IO.userError "boom after a park")

/-- Middleware demonstration: adds a header to every response it wraps. -/
def tag (value : String) : LeanIO.Backend.LeanIn.Middleware :=
  fun handler req w =>
    let w' : LeanIn.Examples.Http.Server.ResponseWriter := {
      start := fun rh => w.start { rh with headers := rh.headers.push ("X-Tag", value) }
      write := w.write
      finish := w.finish
      status := w.status
      code := w.code }
    handler req w'

/-- Form extraction: LeanIO's query parser and `FromForm` over the buffered body. -/
def postForm : Handler :=
  fun req w => do
    match (← (LeanIO.Backend.LeanIn.formBody (Std.HashMap String String) req
            : LeanIn.Runtime.VM (Except (Nat × String) (Std.HashMap String String)))) with
    | .ok m =>
      let user := (m.get? "user").getD ""
      LeanIO.Backend.LeanIn.respond w 200 "OK" s!"user={user}\n".toUTF8
    | .error (status, msg) => LeanIO.Backend.LeanIn.respond w status (reasonFor status) msg.toUTF8

/-- A multipart upload: each part's name, filename and body length. -/
def upload : Handler :=
  LeanIO.Backend.LeanIn.withMultipart fun parts _req w => do
    let describe (p : LeanIO.Backend.LeanIn.Part) : String :=
      s!"{p.name}:{p.filename.getD "-"}:{p.body.size}:{p.contentType}"
    LeanIO.Backend.LeanIn.respond w 200 "OK"
      (s!"parts={parts.size} " ++ String.intercalate " " (parts.toList.map describe) ++ "\n").toUTF8

/-- Echo the request body. The reader delivers it incrementally; this route accumulates it to answer with one
`Content-Length` body, while a streaming route would `recv` and `write` instead. -/
def echo : Handler :=
  fun req w => do
    let body ← LeanIO.Backend.LeanIn.readAll req.body .empty
    LeanIO.Backend.LeanIn.respond w 200 "OK" body

def routes (clock : LeanIn.Runtime.Clock) : LeanIO.Backend.LeanIn.NativeRouter :=
  LeanIO.Backend.LeanIn.NativeRouter.empty
    |>.add (native GET "/ping" ping)
    |>.route .get "/slow" (slow clock)
    |>.route .get "/user/{id}" (tag "users" userById)
    |>.route .post "/echo" echo
    |>.route .post "/todos" postTodo
    |>.route .post "/text" postText
    |>.route .post "/form" postForm
    |>.route .post "/upload" upload
    |>.route .get "/boom" (boom clock)
    |>.route .get "/logged" (LeanIO.Backend.LeanIn.requestLogger "req" ping)
    |>.addMiddleware LeanIO.Backend.LeanIn.catchErrors

end LeanIO.Examples.Native

open LeanIO.Examples.Native

def main (args : List String) : IO UInt32 := do
  let port : UInt16 := ((args.headD "8787").toNat?.getD 8787).toUInt16
  let hooks ← LeanIn.Runtime.Hooks.new
  let clock := LeanIn.Runtime.Clock.live hooks
  LeanIO.Backend.LeanIn.serveWith hooks (LeanIO.Backend.LeanIn.dispatch (routes clock).toTrie) port
