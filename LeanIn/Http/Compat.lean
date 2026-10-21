module

public import Std.Http.Server
public import LeanIn.Http.Server
public import LeanIn.Http.H1

public section
/-!
# Stock `Std.Http.Server.Handler` compatibility

Run a stock handler as a LeanIn buffered handler. The request body is already buffered by LeanIn's driver, so the
stock `Body.Stream` is built from those bytes (`Std.Http.Body.stream` + `Stream.send`), and the stock response body
is drained through the `Std.Http.Body` interface.

This is a **compatibility** path, not the streaming path: the stock handler is run to completion with
`Std.Async.Async.block` on the calling carrier, so it cannot interleave with other work while suspended. Use
LeanIn's `StreamHandler` for serving code.
-/

namespace LeanIn.Http.Compat

open LeanIn.Http

/-- H1's method to the stock method. An unclassified token goes through `Std.Http.Method.ofString?`. -/
def methodToStock (h : H1.Head) : Except IO.Error Std.Http.Method :=
  match h.method with
  | .get => .ok .get
  | .head => .ok .head
  | .post => .ok .post
  | .put => .ok .put
  | .delete => .ok .delete
  | .options => .ok .options
  | .patch => .ok .patch
  | .trace => .ok .trace
  | .connect => .ok .connect
  | .other =>
      match Std.Http.Method.ofString? h.methodTokenString with
      | some m => .ok m
      | none => .error (.userError s!"Http.Compat: unknown method {h.methodTokenString}")

def versionToStock (v : H1.Version) : Std.Http.Version :=
  match v with | .v10 => .v10 | .v11 => .v11

/-- The request head, with the header slices resolved to stock names and values. -/
def headToStock (h : H1.Head) : Except IO.Error Std.Http.Request.Head := do
  let method ← methodToStock h
  let uri ← match Std.Http.RequestTarget.parse? h.targetString with
    | some u => pure u
    | none => throw (.userError s!"Http.Compat: invalid request target {h.targetString}")
  let mut headers := Std.Http.Headers.empty
  for (n, v) in h.headers do
    let name ← match H1.Slice.toString? h.buf n with
      | some s => pure s
      | none => throw (.userError "Http.Compat: a header name is not UTF-8")
    let value ← match H1.Slice.toString? h.buf v with
      | some s => pure s
      | none => throw (.userError "Http.Compat: a header value is not UTF-8")
    let some stockName := Std.Http.Header.Name.ofString? name
      | throw (.userError s!"Http.Compat: invalid header name {name}")
    let some stockValue := Std.Http.Header.Value.ofString? value
      | throw (.userError s!"Http.Compat: invalid header value {value}")
    headers := headers.insert stockName stockValue
  return { method, version := versionToStock h.version, uri, headers }

/-- A stock body stream over bytes LeanIn has already buffered. -/
def bodyStream (body : ByteArray) : IO Std.Http.Body.Stream :=
  Std.Async.Async.block (Std.Http.Body.stream fun s => do
    unless body.isEmpty do s.send ⟨body, #[]⟩
    s.close)

/-- Drain a stock response body through its `Std.Http.Body` instance. -/
partial def readBody {α : Type} (inst : Std.Http.Body α) (body : α) (acc : ByteArray := .empty) :
    Std.Async.Async ByteArray := do
  match ← Std.Http.Body.recv (self := inst) body with
  | some chunk => readBody inst body (acc ++ chunk.data)
  | none => pure acc

/-- Convert a stock response to LeanIn's buffered response. -/
def responseToLeanIn {α : Type} (inst : Std.Http.Body α) (r : Std.Http.Response α) :
    Std.Async.Async (H1.ResponseHead × ByteArray) := do
  let body ← readBody inst r.body
  Std.Http.Body.close (self := inst) r.body
  let headers := (r.line.headers.toList.map (fun (n, v) => (n.value, v.value))).toArray
  return ({ status := r.line.status.toCode.toNat, reason := r.line.status.reasonPhrase, headers }, body)

/-- Run a stock handler as a LeanIn buffered handler. The stock handler's suspensions are run on the stock
async runtime, which blocks the calling carrier until it completes. -/
def ofStock {σ : Type} (h : Std.Http.Server.Handler σ) (state : σ) : Server.Handler :=
  fun head body => do
    let stockHead ← match headToStock head with
      | .ok h => pure h
      | .error e => throw e
    let stream ← monadLift (bodyStream body)
    let ctx ← monadLift Std.CancellationContext.new
    let request : Std.Http.Request Std.Http.Body.Stream := { line := stockHead, body := stream }
    let response ← monadLift (Std.Async.Async.block (ReaderT.run (h.onRequest state request) ctx))
    monadLift (Std.Async.Async.block (responseToLeanIn h.responseBodyInstance response))

end LeanIn.Http.Compat
end
