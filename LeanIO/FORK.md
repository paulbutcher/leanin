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
| 2026-10-20 | `Router.Macro`: route syntax is an elaborator; `leanio.backend.native` option; `native … => …` and `nativeRoute` syntax; `Backend.LeanIn` handlers take `BodyReader`/`ResponseWriter`; `AppM` and native extractor classes | the unprefixed route syntax selects a backend by option, and streaming request and response bodies |
| 2026-10-20 | `MultiPartForm` parameterised over `BodySource m body` (defaults `ContextAsync`/`Body.Stream`); native `BodySource VM BodyReader`; `readUntilGo` extracts from the read's start position | one upstream multipart parser serves both backends; the cursor fix makes headers split across reads parse correctly |

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

Handlers use the streaming session: `Request.body` is a `BodyReader`, the handler writes through a
`ResponseWriter`, and neither direction is accumulated. `readAll` is what a buffered extractor (`jsonBody`,
`formBody`) calls; a route that streams calls `recv`/`write` itself. Responses are framed as a declared
`Content-Length`, chunked on HTTP/1.1, or close-delimited. The buffered `maxBody` limit applies only to the
buffered driver; a streaming body has no accumulated body to bound.

Route selection shares the route-declaration form. The unprefixed `GET … => …` selects the stock backend by
default and the native backend under `set_option leanio.backend.native true`; `native GET … => …` selects the
native backend regardless of the option. A native body is an `AppM` computation (request and writer in the
environment) and binders read through the native `FromRequestBodyM`/`NativeExtractor` classes;
`nativeRoute GET "/ping" ping` takes an already-built handler.

Multipart is the upstream parser parameterised over its body source: `BodySource m body` with defaults
`ContextAsync`/`Body.Stream` keeps the stock API unchanged, and the native backend adds
`BodySource VM BodyReader`. `MultiPartForm`/`FormFile`/`MultipartEntry` are therefore the same types and
operations on both backends - `nextEntry`, `stream`, `discard`, `save` - and `withMultipartForm` runs them
over the native request reader. One parser serves both.

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
