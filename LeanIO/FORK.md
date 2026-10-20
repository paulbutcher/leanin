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
| 2026-10-20 | `Router.Macro`: `native`/`nativeRoute` syntax; `Backend.LeanIn` handlers take `BodyReader`/`ResponseWriter` | explicit backend selection, and streaming request and response bodies on the native backend |

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

### The native backend's boundary

Handlers now use the streaming session: `Request.body` is a `BodyReader`, the handler writes through a
`ResponseWriter`, and neither direction is accumulated. `readAll` is what a buffered extractor (`jsonBody`,
`formBody`, multipart) calls; a route that streams calls `recv`/`write` itself. The response is framed as a
declared `Content-Length`, chunked on HTTP/1.1, or close-delimited. The buffered `maxBody` limit applies only
to the buffered driver; a streaming body has no accumulated body to bound.

Route selection is explicit: `native GET "/ping" ping` (also `nativeRoute`) declares a route whose handler is
the backend's `Request → ResponseWriter → VM Unit`. The upstream `GET … => …` syntax remains stock-LeanIO and
does not select a backend; its extractor classes are still typed at `ContextAsync`.

Multipart is parsed from the reader's bytes (`withMultipart`) and returns whole parts, so a part body is
buffered per request. A per-part streaming reader, and the upstream multipart API over it, are not ported.

Cancellation is the transport's: a body or response operation that fails raises through the handler, and
`catchErrors` re-raises transport failures rather than turning them into a 500 the peer can no longer receive.

## Working rules

- The fork builds together with the rest of the package: `nix develop -c lake build LeanIO`.
- Divergent edits are listed above as they are made; a sync from upstream must re-apply this log.
- Behavioural changes that affect LeanIO's public API are recorded here, not only in a commit message.
- The porting plan and the feature gaps it requires from LeanIn are in
  `docs/notes/LeanIO_to_LeanIn_Porting_Handoff.md`; the backend's effect signature is
  `docs/notes/LeanIO_to_LeanIn_Effect_Signature.md`.
- Run `nix develop -c bash tests/leanio-native.sh` after touching the backend or the HTTP driver.
