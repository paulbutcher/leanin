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

namespace LeanIO.Examples.Native

open LeanIn.Examples.Http

def ping : Handler :=
  fun _ _body => pure (LeanIO.Backend.LeanIn.response 200 "OK" "pong\n".toUTF8)

def slow (clock : LeanIn.Runtime.Clock) : Handler :=
  fun _ _body => do
    let _ ← LeanIn.Runtime.VM.sleep clock 200
    pure (LeanIO.Backend.LeanIn.response 200 "OK" "slept\n".toUTF8)

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
  fun head body =>
    match (LeanIO.Backend.LeanIn.jsonBody Todo { head, body } : Except (Nat × String) Todo) with
    | .ok todo => pure (LeanIO.Backend.LeanIn.response 200 "OK" (Lean.toJson todo).compress.toUTF8)
    | .error (status, msg) => pure (LeanIO.Backend.LeanIn.response status (reasonFor status) msg.toUTF8)

/-- Plain-text extraction with the same media-type contract. -/
def postText : Handler :=
  fun head body =>
    match LeanIO.Backend.LeanIn.textBody { head, body } with
    | .ok text => pure (LeanIO.Backend.LeanIn.response 200 "OK" s!"text: {text}\n".toUTF8)
    | .error (status, msg) => pure (LeanIO.Backend.LeanIn.response status (reasonFor status) msg.toUTF8)

/-- Form extraction: LeanIO's query parser and `FromForm` over the buffered body. -/
def postForm : Handler :=
  fun head body =>
    match (LeanIO.Backend.LeanIn.formBody (Std.HashMap String String) { head, body }
            : Except (Nat × String) (Std.HashMap String String)) with
    | .ok m =>
      let user := (m.get? "user").getD ""
      pure (LeanIO.Backend.LeanIn.response 200 "OK" s!"user={user}\n".toUTF8)
    | .error (status, msg) => pure (LeanIO.Backend.LeanIn.response status (reasonFor status) msg.toUTF8)

/-- Echo the buffered request body, at whatever length the body delivered. -/
def echo : Handler :=
  fun _ body => pure (LeanIO.Backend.LeanIn.response 200 "OK" body)

def routes (clock : LeanIn.Runtime.Clock) : RouteTrie Handler :=
  (RouteTrie.empty : RouteTrie Handler)
    |>.addRoute .get [Segment.lit "ping"] ping
    |>.addRoute .get [Segment.lit "slow"] (slow clock)
    |>.addRoute .post [Segment.lit "echo"] echo
    |>.addRoute .post [Segment.lit "todos"] postTodo
    |>.addRoute .post [Segment.lit "text"] postText
    |>.addRoute .post [Segment.lit "form"] postForm

end LeanIO.Examples.Native

open LeanIO.Examples.Native

def main (args : List String) : IO UInt32 := do
  let port : UInt16 := ((args.headD "8787").toNat?.getD 8787).toUInt16
  let hooks ← LeanIn.Runtime.Hooks.new
  let clock := LeanIn.Runtime.Clock.live hooks
  LeanIO.Backend.LeanIn.serveWith hooks (LeanIO.Backend.LeanIn.dispatch (routes clock)) port
