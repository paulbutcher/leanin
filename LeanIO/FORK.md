# LeanIO: a fork maintained in this repository

Base: `ecyrbe/leanio` at `0bb212d57f3dba2d76cf601f76a7c431a51c902e`, MIT licensed (see `LICENSE`; the upstream
copyright notice is retained). This copy is a **fork**, not a vendored snapshot: it is modified here, and its
backend is being moved onto LeanIn. Upstream changes are not merged automatically.

## Divergence log

| date | change | why |
| --- | --- | --- |
| 2026-10-20 | `Data/Headers/HeaderName.lean`: removed `contentEncoding`, `ifNoneMatch`, `lastModified`, `ifModifiedSince` | `Std.Http.Header.Name` provides them in Lean 4.35.0 |
| 2026-10-20 | tests moved from `Tests.*` to `LeanIO.Tests.*` | they live inside the fork's namespace |
| 2026-10-20 | `Router.RouteTrie` parameterised over its handler value (`RouteTrie H`); `RouteTrie HandlerFn` is the upstream instantiation | the LeanIn backend needs the same trie, lookup and fold over a native handler type; `dispatch` and the `Std.Http.Server.Handler` instance stay typed at `HandlerFn` |

## Port status

The fork's backend has been moved onto LeanIn for the native path:

| piece | state |
| --- | --- |
| routing | upstream trie parameterised over its handler value; `NativeRouter` provides the upstream composition semantics natively — route middlewares innermost, then the router's with the last added outermost, mounts prefixing, `notFound`, and a one-time `toTrie` — and `LeanIO.Backend.LeanIn` dispatches it on a LeanIn connection |
| method | token preserved by `H1.Head`, mapped to `Std.Http.Method` or refused (501); a known method with no route is 405 with `Allow`; HEAD is served by the GET handler with the body dropped and `Content-Length: 0`, as upstream documents |
| bodies | buffered delivery to handlers, bounded by `H1.Limits.maxBody` (1 MiB, 413); malformed/oversized heads answer 400/413/431 before close |
| extraction | JSON, plain text and URL-encoded form over the buffered body (415/400/422), reusing LeanIO's MIME declarations, query parser and `FromForm` |
| request | path parameters captured by the trie, query string/parameter decoding, headers, media type; `withExtract` composes an extractor with a handler; `Middleware := Handler → Handler` |
| suspension | handlers are `VM` values; `GET /slow` parks 200 ms while a sibling request completes |
| middleware | `Handler → Handler`; `catchErrors` uses `VM.attempt`, whose catch survives a suspension (`/boom` parks then raises, answered 500), and `requestLogger` observes and passes through |
| checks | `tests/leanio-native.sh` asserts all of the above at the public socket |

Not yet ported: the route macros and `FromRequestBody`/`FromRequestParts` classes still ascribe
`ContextAsync`/`Request Body.Stream`; streaming bodies/backpressure, multipart and the request-cancellation
scope are later stages. The fork builds and its own tests run under `lake build LeanIO`.

### The authoring seam is blocked by the module-system boundary

`LeanIO/Router/Macro.lean` is a `module` file, and a `module` file cannot import a non-`module` one. LeanIn is
not written in the module system, and neither is `LeanIO/Backend/LeanIn.lean` (it imports LeanIn). A
backend-parameterised route macro therefore cannot refer to the native backend's types as things stand.

Two ways out, to choose deliberately:

1. **Convert to the module system** — LeanIn (its whole dependency closure) and the backend, so a `module`
   macro can import them. Mechanical per file (`module` plus `public import` at re-export points) but it changes
   re-export behaviour: code that relied on transitive names from a module's imports may need explicit imports.
2. **An explicit native declaration syntax** in a non-module file (e.g. `LeanIO/NativeSyntax.lean`) with its own
   keyword, leaving upstream's macros stock-only. Narrow and safe, but the route declaration syntax is not shared.

Until that decision is taken, native route declaration is programmatic (`NativeRouter.route`) and
`NativeRouter.routeWith` with the helpers in `LeanIO.Backend.LeanIn`.

## Working rules

- The fork builds together with the rest of the package: `nix develop -c lake build LeanIO`.
- Divergent edits are listed above as they are made; a sync from upstream must re-apply this log.
- Behavioural changes that affect LeanIO's public API are recorded here, not only in a commit message.
- The porting plan and the feature gaps it requires from LeanIn are in
  `docs/notes/LeanIO_to_LeanIn_Porting_Handoff.md`; the backend's effect signature is
  `docs/notes/LeanIO_to_LeanIn_Effect_Signature.md`.
- Run `nix develop -c bash tests/leanio-native.sh` after touching the backend or the HTTP driver.
