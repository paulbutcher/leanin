# The LeanIO backend's effect signature, after Frank

Status: design decision for the port. It borrows Frank's shape (Lindley, McBride, McLaughlin, "Do Be Do
Be Do") for the application-facing interface; it does not claim Frank's type-and-effect system, which Lean
does not implement here.

## What we take from Frank

1. **Effects are abilities, named and typed.** A computation is typed by a signature of abilities it may
   perform; the operations are the abilities' methods, not a bag of monad actions. So the backend's
   application interface is a **signature**, not `ContextAsync` renamed:

   | ability | operations | what a handler must decide |
   | --- | --- | --- |
   | `recv` | receive up to n bytes, EOF, failure | body framing, limits, unread-body drain |
   | `send` | write chunks, flush, close | response framing, backpressure, half-close |
   | `sleep` | wait until an instant or a deadline | cancellation on disconnect/shutdown |
   | `spawn` | child computation, scoped | ownership of child failure and of its completion |
   | `throw` | raise, catch | middleware error scope, including across suspensions |
   | `io` | blocking filesystem work | which pool carries it |

2. **Handlers are typed transformers of a signature.** Middleware is a handler for a sub-signature:
   `catchErrors` handles `throw`, `requestLogger` observes (performs nothing), `auth` may perform `recv`/`throw`
   and must not silently swallow cancellation. Composition order is the nesting order of handlers, which is
   exactly the property the middleware tests check.
3. **Deep handling and one return clause.** The session's driver is the deep handler for `recv`/`send`/`sleep`:
   it owns the connection loop, so a suspension does not escape to the route author. A route handler sees only
   `AppM`; it never sees a completion cell, a push function or a loop.
4. **Reasoning per ability, not per implementation.** Each ability carries a contract (pre/post, and what a
   handler must preserve). LeanIn already states primitive contracts in `LeanIn/Theory/Bridge.lean` and models
   the service in `LeanIn/Model/Service.lean`; the backend's signature is the application-level face of those.
   A handler is correct when it preserves the contracts of the abilities it does not handle and implements the
   one it does.

## What we deliberately do not take

- **No inferred effect rows.** Frank infers a computation's effects; the `async` compiler here classifies
  `await` sites syntactically and the application monad is a concrete Lean type. The signature is therefore a
  documented contract plus a Lean structure, not a checked row system. Saying otherwise would be a false claim,
  and a `MonadExcept` instance is not evidence of Frank's handler typing.
- **No polymorphic handlers over arbitrary signatures** until the compiler can compile them. The first backend
  fixes one signature; parameterising it later is a compiler-generalisation step, as the porting plan says.

## Consequences for the first backend

- `AppM` is defined as a computation over the signature above, with operations that map onto LeanIn primitives
  (`Io.recvRaw`/`recvStallRaw`, `sendRaw`/`sendAllRaw`, `sleepRaw`, spawn, `closeRaw`).
- The request scope (cancellation, cleanup) is a handler *around* the route computation, so a middleware that
  catches errors cannot accidentally catch a cancellation meant for the scope: they are different abilities.
- Each ability gets a contract test at the boundary: body framing and unread-body drain for `recv`, ordering and
  half-close for `send`, cancellation for `sleep`/spawn, exactly-once cleanup for `throw`/scope exit.
- The method token is preserved (or refused explicitly) at the `recv`/parse boundary rather than collapsed:
  Std's `Method` has no `other` constructor, so an unknown token must not become a different known method.
