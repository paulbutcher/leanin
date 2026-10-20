import LeanIn
import LeanIn.Examples.Http.H1
import LeanIn.Examples.Http.Server
import LeanIO.Router.RouteTrie
import Std.Http.Data.Method

/-!
# The LeanIn backend

Routes stored over a LeanIn handler value (`RouteTrie Handler`) and dispatched on a LeanIn connection. The
handler type is the HTTP example's: `Head → VM (ResponseHead × ByteArray)`. This backend is an application of the
toolkit, not part of the library, and it is the first slice of the LeanIO port: metadata-only dispatch, with the
request method preserved as a token and unknown methods refused explicitly.

The application-facing effect signature and the reasoning obligations are
`docs/notes/LeanIO_to_LeanIn_Effect_Signature.md`. The request-body path, streaming responses and request scope
are not here yet; they are the next stages of `docs/notes/LeanIO_to_LeanIn_Porting_Handoff.md`.
-/

namespace LeanIO.Backend.LeanIn

open LeanIn
open LeanIn.Examples.Http
open LeanIO.Router
open Std.Http

/-- A handler the LeanIn driver runs. Suspensions are the `async` compiler's classified effects. -/
abbrev Handler := LeanIn.Examples.Http.Server.Handler

/-- The method token as `Std.Http.Method`, or `none` when the token is not one it names. Unknown methods are
refused explicitly at dispatch; they are never mapped onto a different method. -/
def method? (h : H1.Head) : Option Std.Http.Method :=
  Std.Http.Method.ofString? h.methodTokenString

/-- Percent-decode `s`; `+` becomes a space when `plusIsSpace` (query values), and stays literal in a path. -/
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

/-- The path segments of a request target, query removed and each segment percent-decoded. -/
def segments (h : H1.Head) : List String :=
  let target := h.targetString
  let path := (target.splitOn "?").headD target
  (path.splitOn "/").filter (fun s => !s.isEmpty) |>.map (fun s => pctDecode s false)

/-- A response with one buffered body and a `Content-Length`. -/
def response (status : Nat) (reason : String) (body : ByteArray)
    (headers : Array (String × String) := #[]) : H1.ResponseHead × ByteArray :=
  ({ status, reason, headers := headers.push ("Content-Length", toString body.size) }, body)

/-- Dispatch a parsed head through the trie.

An unknown method token is refused with 501 rather than dispatched. A path known under other methods answers 405
with `Allow`; a miss goes to the trie's `notFound` handler or a 404. Middlewares are expected to be composed
onto handlers before insertion, as in the upstream trie. -/
def dispatch (trie : RouteTrie Handler) : Handler := fun h body =>
  match method? h with
  | none => pure (response 501 "Not Implemented" "method not supported\n".toUTF8)
  | some m =>
    match trie.lookup m (segments h) with
    | .found _ handler => handler h body
    | .methodMismatch allowed =>
      pure (response 405 "Method Not Allowed" "".toUTF8 #[("Allow", RouteTrie.allowValue allowed)])
    | .noMatch =>
      match trie.notFound with
      | some handler => handler h body
      | none => pure (response 404 "Not Found" "not found\n".toUTF8)

/-- Serve `handler` on `port` with the given hooks (so an application can build handlers against the same live
clock, e.g. to suspend on a timer). Blocks until the accept loop ends. -/
def serveWith (hooks : LeanIn.Runtime.Hooks) (handler : Handler) (port : UInt16) : IO UInt32 := do
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
def serve (handler : Handler) (port : UInt16) : IO UInt32 := do
  let hooks ← LeanIn.Runtime.Hooks.new
  serveWith hooks handler port

end LeanIO.Backend.LeanIn
