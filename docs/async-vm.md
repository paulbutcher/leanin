# The defunctionalization approach (`async!` / the `VM`)

Status: **a working `Std.Http` replacement.** `LeanIn/Runtime/HttpServer.lean` is an HTTP/1.1 server on the
`asyncMachine` engine — each connection's `serveConn` compiles the full H1 drive (the `vmDrive` shape: `pump`
the machine, write, then `halted`? close : `recvTimeout` → EOF/stalled/feed) to a per-function state machine.
`asyncMachine` lowers `await`-suspensions, inlines pure code, and lowers `if`/`match` control flow to state
transitions, threads the H1 machine across requests as a field, and routes constant parameters (the clock, the
deadline, the handler) to **step parameters** like the connection. Validated end-to-end (GET, keep-alive, POST
bodies, concurrent connections, **partial-read reassembly**, the **stall deadline**) and benchmarked: **~20×
faster than the shipped `Std.Http.Server`** and **C=1 at/ahead of Node parity** (below). Pieces 1–2 (raw
delivery, the `VM`) validated earlier. The handler is now a **`VM` computation** (`Head → VM (Response.Head ×
ByteArray)`), so it may suspend — read a backend, wait — and its suspension joins the connection's machine
through `VM.runAsync` (a fresh `RawCell` the sub-computation resolves); a handler that is pure is answered
inside `pump` with no cell and no state hop, so the common case pays nothing for the async machinery being
available. The remaining engine gap is `loop`.

## Goal

A Tokio-style concurrency engine for Lean whose steady-state performance is within ~1.5× of Node. The HTTP
server is the vehicle, not the point: the point is the general engine a client writes async code against.

## The problem, measured

The merged single-carrier driver (the serving carrier pumps the I/O loop itself) removed the cross-thread
handoff, so the I/O model and scheduler are no longer the gap. What remains is **per-request heap churn in the
async machinery**, not the I/O. Profiling (`callgrind`) of `serveConn`:

- ~47% of instructions are memory management (alloc / free / refcount / GC mark), ~9% closure application.
- The actual HTTP parse+write is **under 2%**.

Two kinds of allocation make up that churn:

1. **The engine's completion delivery** — every suspension (`recv`/`send`/`await`) allocates a `Join` cell, a
   waiter, an `Item`, and an `Item.ofDeferred` closure, and pays the inject + carrier-fire round trip.
2. **The client's own CPS closures** — every `←` in a client's `do` block is a `bind` whose continuation is a
   freshly allocated closure. This is the larger, *general* cost: you cannot hand-optimize it per loop.

## The approach: defunctionalization

Make a suspended computation **data** instead of a closure, and resume it **directly** instead of through the
cell+item apparatus. Client code still *reads* like async (`do` with `←`); under it, the continuation is a
machine state the engine resumes in place.

Three pieces, in increasing order of polish:

### 1. Raw delivery (engine-side) — done, validated

`Io.recvRaw` / `Io.sendRaw` / `Io.registerRaw`: a completion resumes its continuation *on the loop thread*,
with **no** `Join` cell, `Item`, inject, or carrier fire. This is the resume mechanism everything else uses.

*Measurement* (plain TCP echo, CPS echo vs raw echo, `callgrind`): **67.4k → 29.7k instructions/request
(−56%)**; C=32 throughput +27%.

### 2. The `VM` monad (client-side) — done, validated

`LeanIn/Runtime/VM.lean`: a free machine over the socket effects with a `Monad` instance, so a client writes
**ordinary `do`** and it elaborates into machine data; the incremental interpreter (`VM.runK`) resumes each
effect by raw delivery. This is the general mechanism — no hand-defunctionalizing each loop.

*Measurement* (echo written as `do` in `VM`, `callgrind`): **30.9k instructions/request (−54% vs CPS)**, within
~6% of the hand-written raw echo. C=32 throughput +22% over CPS.

Lean obstacles hit and cleared: free-monad `bind` won't compile as `partial` (Lean can't prove `VM β` nonempty
for the fallback), and a `bind`-constructor GADT hits a universe error on the indexed type. Working form:
parameterized `VM` + `partial` bind + a default `.empty` constructor for the `Inhabited` the fallback needs.

### 3. The `async!` elaborator (`asyncMachine`) — done, with control flow, on the real drive

`LeanIn/Async.lean`: `asyncMachine name (c : Conn) (x : T) … := do …` compiles a `do` block to a **flat state
machine** — one inductive constructor per suspension point, carrying the live variables, plus a `step` function
the driver matches on — resumed through the same raw delivery. Suspensions are marked `await (e)`; the body is
lowered **recursively**: pure code is inlined into the current state's step, each `await` suspends, and
`if`/`recurse` become transitions between states. A **liveness analysis** decides which variables each state
carries as fields. The first parameter `(c : Conn)` is the connection (a constant step parameter); further
parameters are **threaded fields** — state 0 carries them and `recurse` passes their current values back, which
is how the H1 machine is threaded across requests. A control-flow item mid-sequence hoists the rest into a
*shared* continuation state, so converging paths compile once; field types are inferred without a general
elaboration pass (a threaded parameter keeps its signature type, a `recvRaw` result is `ByteArray`, a
`sendAllRaw` argument is `Array ByteArray`, an `if`-condition is `Bool`).

Validated on the echo (keep-alive), then on **`serveConn`'s actual connection drive** — not the stateless
benchmark shape. `serveConn` pumps the H1 machine (`pump`: the pure step + `endHeaders`-handler + progress
loop, the part of `vmDrive` between the socket effects), writes any output, then branches on `halted` to close
or `recvRaw` → `feed` → `recurse`. Two macro-level bugs were the real work: dot-notation like `m.feed` is a
single compound identifier, so the liveness had to collect each identifier's **root** (`m`) or it dropped the
machine from a state's fields; and a shadowing pure bind (`let m := m.feed bs`) had to keep the threaded
binding's type rather than reset it to the inference fallback. `match` and `recvTimeout` (with the stall
`Clock`) are the remaining gaps; the `match` quotation needs the same array-splice form the step uses.

*Measurement* (`bench/load.mjs`, keep-alive, sequential request-response, 5 s runs, `maxMessages`/`maxRequests`
raised past the H1 default of 100 on both Lean servers — see below). The replacement
(`LeanIn/Runtime/HttpServer.serveConn`) against the shipped **`Std.Http.Server`** (`StdServer.lean`) and Node
(`bench/node-server.mjs`):

| C | leanin `HttpServer` | shipped `Std.Http.Server` | Node |
|---|---|---|---|
| 1 | **50 300** | 2 333 | 45 466 |
| 8 | **39 414** | 3 190 | 81 441 |
| 32 | **58 096** | 3 285 | 102 598 |

**The replacement is ~18–22× faster than the shipped `Std.Http.Server`** at every level (the shipped server is
on the stock task pool, whose priority deques sit behind one mutex — see `docs/PERFORMANCE.md`), and **at C=1 it
is at/ahead of Node parity** (1.11× here; earlier interleaved runs read 0.81–1.05×, i.e. the same band within
this repository's ±30% drift). At C=8/C=32 Node pulls ahead (the single-carrier ceiling, as W16 recorded).
errors=0 throughout. Correctness beyond throughput: keep-alive, POST bodies, 20 concurrent connections,
**partial-read reassembly** (a request split across three TCP segments), and the **stall deadline** (an idle
connection closed at the deadline, confirmed on the wire).

**Threading the machine surfaced a real behaviour difference, not a benchmark artefact.** The stateless `amHttp`
built a fresh H1 machine per request, so its `messageCount` never accumulated; the threaded `serveConn` carries
it, so at 100 requests the machine emits `Connection: close` and closes — the H1 default `maxMessages = 100`, a
production keep-alive cap. The *shipped* `Std.Http.Server` has the same cap (`maxRequests = 100` →
`maxMessages`), so at the default it reads ~20 req/s here (100 requests then close); the benchmark raises both
caps to match Node, which applies no per-connection request cap.

## Where this lands against Node

**Update — serveConn in `VM` (the real benchmark path).** `VMHttp.vmServeConn` is `serveConn`'s connection loop
in the `VM` monad: the H1 machine stepping, event processing and branching stay pure; only `recv`/`sendAll`/
`close` are effects, resumed by raw delivery. Measured against `serveConn` on the HTTP benchmark:

| | serveConn | VM serveConn | win |
|---|---|---|---|
| instructions/request | 200794 | **106749** | **−47%** |
| C=32 req/s | 25210 | 44140 | **+75%** |
| C=32 p50 | 1223 µs | 658 µs | **−46%** |

The −47% decomposes as ~23 points from removing the stall timeout and **~30 points from the delivery VM
itself** (the no-timeout spike's ~154k → 107k). The C=32 throughput (44140 req/s) is at parity with Node's
C=32 on this harness — from ~2× behind to comparable on the multi-connection shape. The delivery VM is
**necessary but not sufficient** for a comfortable 1.5×: it captures the delivery machinery, but the H1 layer
(below) is the larger remaining target.

Prior framing, still accurate: the delivery VM alone is **necessary but not sufficient** for 1.5×. Rough
per-request decomposition of `serveConn` (from the echo experiment + timeout spikes): delivery machinery ~16%,
`withTimeout` race ~20%, **HTTP layer (H1 machine + response encode) ~50%**, socket+misc ~14%. So:

- delivery VM → ~2.0× Node; + a cheap `recvTimeout` → **~1.5×**, the HTTP+socket floor.
- Beating 1.5× comfortably needs the H1 layer reimplemented to allocate far less (Node's llhttp is C,
  zero-copy; ours is a persistent functional machine). That is a separate, larger project.

## Honesty notes

- Echo is a minimal loop (2 suspensions, no H1/handler); `serveConn` carries irreducible H1+handler on top, so
  its *percentage* win is smaller — the per-suspension machinery is identical.
- The VM's interpreter runs the client on the loop thread (right for the single-carrier driver; multi-carrier
  needs thought). Raw delivery parks the loop per op; a batching VM would keep switches low.
- All of this is experiment-quality (`VM.lean`, the raw path in `Io.lean`, `DefuncEcho.lean`); gate holds 22/22.
