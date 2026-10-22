module

public import LeanIn.Http.StdHandler
public import LeanIn.Http.Stock

public section
/-!
# The shared handler contract, instantiated for both hosts

These definitions are compile-time witnesses: the same middleware and body helper are used with the LeanIn
adapter and the stock adapter, and neither definition mentions a host-specific body or monad.
-/

namespace LeanIn.Test.HandlerContract

open LeanIn.Http
open LeanIn.Runtime

/-- The same header middleware for both hosts. -/
def withContractHeader {m : Type → Type} [Monad m] {n : Type → Type} [Monad n]
    {ReqBody ResBody : Type} (h : HandlerM m n ReqBody ResBody) : HandlerM m n ReqBody ResBody :=
  withHeader (Std.Http.Header.Name.ofString! "x-contract") (Std.Http.Header.Value.ofString! "yes") h

/-- The LeanIn instantiation. -/
def leanin (body : Std.Http.Response ResponseBody) : StdHandler :=
  withContractHeader { onRequest := fun _ => pure body }

/-- The stock instantiation. -/
def stock (body : Std.Http.Body.Any) : Stock.Handler :=
  withContractHeader { onRequest := fun _ => pure { body } }

/-- One body helper, read through the LeanIn reader. -/
def leaninBody (request : Std.Http.Request Server.BodyReader) : VM ByteArray :=
  readAllBody request.body

/-- The same body helper, read through the stock stream. -/
def stockBody (request : Std.Http.Request Std.Http.Body.Stream) : Std.Async.ContextAsync ByteArray :=
  readAllBody request.body

end LeanIn.Test.HandlerContract
end
