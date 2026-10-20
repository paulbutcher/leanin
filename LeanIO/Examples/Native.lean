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

/-- Echo the buffered request body, at whatever length the body delivered. -/
def echo : Handler :=
  fun _ body => pure (LeanIO.Backend.LeanIn.response 200 "OK" body)

def routes (clock : LeanIn.Runtime.Clock) : RouteTrie Handler :=
  (RouteTrie.empty : RouteTrie Handler)
    |>.addRoute .get [Segment.lit "ping"] ping
    |>.addRoute .get [Segment.lit "slow"] (slow clock)
    |>.addRoute .post [Segment.lit "echo"] echo

end LeanIO.Examples.Native

open LeanIO.Examples.Native

def main (args : List String) : IO UInt32 := do
  let port : UInt16 := ((args.headD "8787").toNat?.getD 8787).toUInt16
  let hooks ← LeanIn.Runtime.Hooks.new
  let clock := LeanIn.Runtime.Clock.live hooks
  LeanIO.Backend.LeanIn.serveWith hooks (LeanIO.Backend.LeanIn.dispatch (routes clock)) port
