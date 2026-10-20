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

### The authoring seam

Route declaration for the native backend is syntax, not only the programmatic API:

```lean4
|>.add (nativeRoute GET "/ping" ping)
```

`nativeRoute` is declared in `LeanIO/Router/Macro.lean`, beside the method keywords and pattern validation it
reuses, and expands to a `NativeRoute` with the backend's `Request → VM (ResponseHead × ByteArray)` handler.
`NativeRouter.add` consumes it.

This needed the module-system conversion of LeanIn, `LeanIn/Examples/Http` and the backend: `module` files
cannot import non-module ones, so the backend could not be named from the macro before. With those converted,
the macro names the backend's types directly. The backend's public signatures (`Handler`, `Request.head`) are
what force its `public import` of the HTTP modules, and the compiler reports any import that is too private.

Still programmatic or stock-only: the upstream `GET … => …` syntax keeps its `ContextAsync` handler and does not
select a backend; `FromRequestBody`/`FromRequestParts` remain typed at `Request Body.Stream`. Streaming bodies
and backpressure, multipart, request cancellation, and chunked / `Expect` framing are later stages of the
porting handoff.

## Working rules

- The fork builds together with the rest of the package: `nix develop -c lake build LeanIO`.
- Divergent edits are listed above as they are made; a sync from upstream must re-apply this log.
- Behavioural changes that affect LeanIO's public API are recorded here, not only in a commit message.
- The porting plan and the feature gaps it requires from LeanIn are in
  `docs/notes/LeanIO_to_LeanIn_Porting_Handoff.md`; the backend's effect signature is
  `docs/notes/LeanIO_to_LeanIn_Effect_Signature.md`.
- Run `nix develop -c bash tests/leanio-native.sh` after touching the backend or the HTTP driver.
