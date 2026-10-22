module

public import LeanIn.Http.Contract
public import Std.Http.Server

public section
/-!
# The stock host adapter

The concrete instantiation of `HandlerM` for `Std.Http.Server`: `ContextAsync` for the request, `Async` for the
hooks, `Body.Stream` for the request body and `Body.Any` for the response body. This is the adapter that keeps the
stock distinction rather than coercing one monad into the other.
-/

namespace LeanIn.Http.Stock

open Std Async

/-- A handler the stock server can run. -/
abbrev Handler := HandlerM ContextAsync Async Std.Http.Body.Stream Std.Http.Body.Any

/-- The stock body's `readAll`, as the shared body capability. -/
instance : BodyInput ContextAsync Std.Http.Body.Stream where
  readAll stream := Std.Http.Body.Stream.readAll stream

/-- Run a `Handler` on `Std.Http.Server` without changing its callbacks. -/
def toStatelessHandler (h : Handler) : Std.Http.Server.StatelessHandler :=
  { onRequest := h.onRequest
    onFailure := h.onFailure
    onContinue := h.onContinue }

end LeanIn.Http.Stock
end
