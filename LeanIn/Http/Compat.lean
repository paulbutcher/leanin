module

public import Std.Http.Server
public import LeanIn.Http.Server
public import LeanIn.Http.H1
public import LeanIn.Http.StdHandler

public section
/-!
# Stock `Std.Http.Server.Handler` compatibility

Run a stock handler as a LeanIn buffered handler. The request body is already buffered by LeanIn's driver, so the
stock `Body.Stream` is built from those bytes (`Std.Http.Body.stream` + `Stream.send`), and the stock response body
is drained through the `Std.Http.Body` interface.

This is a **compatibility** path, not the streaming path: the stock handler is run to completion with
`Std.Async.Async.block` on the calling carrier, so it cannot interleave with other work while suspended. Use
LeanIn's `StreamHandler` for serving code.

The stock handler's `onContinue` and `onFailure` are **not** consulted. The buffered driver has sent any
`100 Continue` and read the body before the handler runs, so a refusal could not be honoured here; code that
needs `Std`'s continue and failure contract uses `StdHandler` and `Server.serveConnStd`.
-/

namespace LeanIn.Http.Compat

open LeanIn.Http

/- The head conversion is shared with the `Std`-shaped handler layer, which owns it. -/
export LeanIn.Http.StdHandler (methodToStock versionToStock headToStock)

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
