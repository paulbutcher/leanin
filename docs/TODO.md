# LeanIn TODO

Open work found while serving lean-routing and LeanIO on LeanIn. Ordered by what blocks production
serving, then what the ports exposed as ergonomics or performance, then backend and release work.

## P0 — lifecycle correctness

- [x] **Deadline abort on drain.** `serveUntilStoppedWithDeadline` arms a grace timer when the
  executor starts stopping, cancels the handles the registry still holds, aborts parked operations
  and timers, and then awaits the registry, so a handler parked in a long sleep cannot hold shutdown.
  A drain that finishes first disarms the timer.
  - Evidence: `Runtime.Net.serveUntilStoppedWithDeadline`, `Runtime.stopWithDeadline`,
    `bash tests/drain-deadline.sh` (one client, 60 s handler sleep, 100 ms grace: the request reports
    `aborted`, its scope cleanup runs once, and the loop returns in ~101 ms) and
    `bash tests/stop-deadline.sh` (scope reports `aborted` in ~151 ms).
- [x] **Cancellable parked timers.** Wheel entries carry an `onCancel` and an identity;
  `Clock.scheduleCancel` returns a retirement action, and `VM.sleep` registers it with the ambient
  `Scope`. `Scope.cancelNow` retires the wheel entry immediately (or the driver runs `onCancel` if
  it already took the timer), so a user cancel aborts a parked sleeper without waiting for its
  deadline. `Io.abortAll`/`Io.stop` retire every timer on shutdown.
  - Evidence: `tests/scope-cancel.sh` (a scoped 60 s sleep aborts in ~50 ms) and
    `tests/stop-deadline.sh` (loop-wide abort).
- [x] **Request/handler scope.** `Runtime.Scope` carries a token, live timer retirements, child
  scopes and exit actions. `VM.withScope` creates a request scope (a child when one is active),
  `VM.runScoped`/`runAsyncScoped` exit it exactly once on value, raise or abort, and the streaming
  HTTP driver publishes each request's scope through `Config.onScope`. User cancellation and child
  propagation are exercised by `tests/scope-cancel.sh`; `tests/http-stream.sh` cancels a `/slow`
  handler parked in a sleep and observes EOF with no response bytes.
- [x] **Bound streaming request bodies.** `BodyReader` carries the connection's
  `Config.h1.maxBody` and a delivered-byte count. A declared `Content-Length` over the limit is
  answered `413` before the handler runs; a chunked or fixed read that crosses the limit raises
  `bodyTooLarge`, which the stream driver renders as `413` when the handler has not started its
  response and otherwise closes the connection without retracting bytes already sent.
  - Evidence: `tests/http-stream.sh` streams 2 MiB under the configured 4 MiB ceiling and gets
    `413 Payload Too Large` for a declared 5 MiB body.

## P1 — HTTP serving surface

- [x] **Decoded path/query at the H1 boundary.** `H1.Head.path?` and `H1.Head.query?` split the
  target at the first `?` and percent-decode it in place (`+` as space only in the query); a
  malformed `%HH` returns `none`. Routing outside this repository can consume them instead of
  re-parsing `targetString`.
  - Evidence: `bash tests/h1-target.sh` checks `/a%20b?x=1+y&z=%2F` and a malformed escape.
- [x] **One continue policy.** `Config.continuePolicy` is the single switch: `automatic` keeps the
  machine's safe default, while `application` clears `autoContinue` so a stream handler must call
  `sendContinue`. `Config.limits` derives the machine's view, so the two cannot disagree.
  - Evidence: `tests/http-stream.sh` sends `Expect: 100-continue` and reads the handler's `100`
    before its `200`.
- [x] **General interim responses.** `ResponseWriter.interim` writes any 1xx head before `start`
  (HTTP/1.1 only; a non-1xx status raises), and `sendContinue` remains the 100 case.
  - Evidence: `tests/http-stream.sh` reads `103 Early Hints` before the final `200` from the
    `/hints` route.
- [x] **Multi-carrier serving.** The bind starts the shim's pump thread; `runCarriersWait` starts
  `workers` carriers and waits for the shared-spawned accept loop, and every connection is spawned on
  the shared inject. A connection stays on the carrier that took its first step; the accept chain stays
  on the carrier that ran it. The earlier intermittent stall was `waitFinished` parking the caller on
  the carriers' condition variable: a `notifyOne` from a join resolution could wake the caller (whose
  predicate is only `finished`) and leave the worker parked. `waitFinished` now polls the flag, leaving
  the condition variable to the carriers.
  - Evidence: `tests/multi-server.sh` (15/15 runs, `workers=2`, eight connections) and
    `tests/multi-carrier.sh` (64 shared tasks observed on 3 carriers).
- [x] **Correct the H1 documentation.** The module doc now states the implemented framing,
  continue handling and limits.

## P2 — socket backend (not planned; retained as experiment notes)

- [ ] **io_uring correctness under load.** The direct-ring loop passed functional scenarios but
  produced zero-throughput rounds and process exits at C=8/32. Find the race/lifetime bug before
  any performance claim.
- [ ] **Runtime backend probe/fallback.** Selection is `LEANIN_SHIM=uring` at build time. Add a
  facade with a startup probe (`io_uring_queue_init`, feature flags, seccomp/sysctl), falling back
  to libuv. Keep libuv as the default and portable backend.
- [ ] **C=1 latency experiment.** Best observed is ~0.82× libuv at depth 1; depth-16 is 1.2–1.4×.
  Treat parity at depth 1 as the bar, not a win.

## P3 — compatibility and release

- [x] **Stock `Std.Http.Server.Handler` adapter in LeanIn.** `LeanIn.Http.Compat.ofStock` runs a
  stock handler as a LeanIn buffered handler. It builds the stock `Body.Stream` through the public
  `Std.Http.Body.stream`/`Stream.send`, maps the H1 head and headers to stock types, drains the
  stock response body through `Std.Http.Body`, and maps the status back with `Status.toCode`.
  - Scope: the request body is the already-buffered LeanIn body, and the stock handler is run with
    `Std.Async.Async.block`, so it blocks the calling carrier while suspended. LeanIn's
    `StreamHandler` remains the streaming path.
  - Evidence: `bash tests/compat-handler.sh` (a stock echo handler reads the body, adds a header,
    and the adapter returns status 200, `body=hello`, `x-stock=yes`).
- [x] **`Std.Http`-shaped handler layer** ([#1](https://github.com/scidonia/leanin/issues/1), D24).
  `StdHandler` takes a `Std.Http.Request Server.BodyReader` and returns a `Std.Http.Response ResponseBody`
  in `VM`; `Server.serveConnStd` serves it through the streaming driver, which is unchanged. The request
  carries `RemoteAddr` in `extensions`, a refused `onContinue` answers `417` and closes without running
  the handler, `onFailure` is notified of handler errors, rejected heads and transport aborts, a head `Std`
  rejects answers `400`, and a `Date` is added when the response has none.
  - Evidence: `bash tests/std-handler-contract.sh SH1` (also SH2–SH4) and `bash tests/std-date.sh`.
- [x] **Measure the `Std`-shaped layer.** The stock head conversion costs about a microsecond per header,
  mostly in `Std.Http`'s own validation, and the layer serves 81–89 % of the native keep-alive throughput
  on a two-header request. It stays an opt-in; it does not become the only public handler shape (D24).
  - Evidence: `docs/PERFORMANCE.md`, "The `Std`-shaped handler layer (D24)" (`dispatchBench`,
    `bench/stdpaired.sh`).
- [ ] **Driver-level `onFailure` sites.** A stall before the head (`Std` answers `408`) and a head the
  H1 machine rejects are not reported to a `StdHandler`'s `onFailure`; that needs a hook in
  `driveStream` (D24).
- [ ] **`Compat.ofStock` and the stock hooks.** The buffered adapter does not consult `onContinue` or
  `onFailure`; honouring a refusal means moving it to the streaming path (D24).
- [x] **Release the lifecycle work.** `main` was fast-forwarded and **`v0.6.0`** tagged at
  `466a3a0`; the tag message names the deadline, scope, timer cancellation, streaming bound and
  multi-carrier serving. The package version is `0.6.0`.
- [ ] **Performance record.** Re-run a paired benchmark on a settled host with load average and a
  recorded commit; the current tables are provisional. The original routing/LeanIO pairing target
  moved out with LeanIO, so the target must be restated (Node vs `server`, and the multi-carrier
  arm) before the run.
