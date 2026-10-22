module

public import Std.Http.Data

public section
/-!
# The shared HTTP handler contract

A handler shape that both hosts can use without importing either server implementation. The request monad and the
hook monad are separate on purpose: `Std.Http.Server` calls `onRequest` in `ContextAsync` and the hooks in `Async`,
so collapsing them would either change stock behaviour or force an unchecked coercion.

The records here are metadata only. Bodies remain host types; a capability class names the one operation a helper
needs, so middleware does not acquire a backend-specific body type just to be polymorphic.
-/

namespace LeanIn.Http

/-- A request handler over `Std.Http`'s request and response metadata.

`m` runs the request; `n` runs the two hooks. Keeping `n` separate is what lets the stock adapter use
`ContextAsync` for `onRequest` and `Async` for `onContinue`/`onFailure`, while the LeanIn adapter uses `VM` for
both. -/
structure HandlerM (m : Type → Type) [Monad m] (n : Type → Type) [Monad n]
    (ReqBody ResBody : Type) where
  /-- Answer one request. -/
  onRequest : Std.Http.Request ReqBody → m (Std.Http.Response ResBody)
  /-- Whether to accept `Expect: 100-continue`. -/
  onContinue : Std.Http.Request.Head → n Bool := fun _ => pure true
  /-- A notification of a handler, head or transport failure. The failure still takes its usual course. -/
  onFailure : IO.Error → n Unit := fun _ => pure ()

/-- A middleware transforms a handler of the same request and response types. -/
abbrev MiddlewareM (m : Type → Type) [Monad m] (n : Type → Type) [Monad n]
    (ReqBody ResBody : Type) :=
  HandlerM m n ReqBody ResBody → HandlerM m n ReqBody ResBody

/-- A middleware written once, over any monads and body types: add a response header. -/
def withHeader {m : Type → Type} [Monad m] {n : Type → Type} [Monad n]
    {ReqBody ResBody : Type}
    (name : Std.Http.Header.Name) (value : Std.Http.Header.Value)
    (next : HandlerM m n ReqBody ResBody) : HandlerM m n ReqBody ResBody :=
  { next with
    onRequest := fun request => do
      let response ← next.onRequest request
      return { response with
        line := { response.line with
          headers := response.line.headers.insert name value } } }

/-- One body operation a helper needs. Instances live with the host body type, not here. -/
class BodyInput (m : Type → Type) (β : Type) where
  /-- Read the remaining body. Bounded accumulation is the caller's policy. -/
  readAll : β → m ByteArray

/-- A body-consuming helper written once, over any host body with a `BodyInput` instance. -/
def readAllBody {m : Type → Type} [Monad m] {β : Type} [BodyInput m β] (body : β) : m ByteArray :=
  BodyInput.readAll body

end LeanIn.Http
end
