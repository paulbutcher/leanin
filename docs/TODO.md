# LeanIn TODO

Open work found while serving lean-routing and LeanIO on LeanIn. Ordered by what blocks production
serving, then what the ports exposed as ergonomics or performance, then backend and release work.

## P0 — lifecycle correctness

- [x] **Deadline abort on drain.** `serveUntilStoppedWithDeadline` arms a grace timer when the
  executor starts stopping, cancels the handles the registry still holds, aborts parked operations
  and timers, and then awaits the registry, so a handler parked in a long sleep cannot hold shutdown.
  A drain that finishes first disarms the timer.
  - Evidence: `Runtime.Net.serveUntilStoppedWithDeadline`, `Runtime.stopWithDeadline`,
    `bash tests/drain-deadline.sh` (one client, 60 s handler sleep, 100 ms grace, returns in
    ~101 ms) and `bash tests/stop-deadline.sh` (scope reports `aborted` in ~151 ms).
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

- [ ] **Decoded path/query at the H1 boundary.** `H1.Head` exposes `targetString`; consumers
  re-parse and percent-decode with `Std.Http.RequestTarget.parse?` per request. Add slice-based
  decoded path/query views, and use them from routing to remove the per-request parse.
- [ ] **One continue policy.** `Limits.autoContinue` defaults true and is independent of a
  handler's `onContinue`; a router's decision is ignored unless the config also turns
  `autoContinue` off. Make the policy single and explicit, with a safe default.
- [x] **General interim responses.** `ResponseWriter.interim` writes any 1xx head before `start`
  (HTTP/1.1 only; a non-1xx status raises), and `sendContinue` remains the 100 case.
  - Evidence: `tests/http-stream.sh` reads `103 Early Hints` before the final `200` from the
    `/hints` route.
- [ ] **Multi-carrier serving.** The shipped HTTP entry points are single-carrier; wire a
  multi-carrier accept/connection path and state the affinity rules.
- [x] **Correct the H1 documentation.** The module doc now states the implemented framing,
  continue handling and limits.

## P2 — socket backend

- [ ] **io_uring correctness under load.** The direct-ring loop passed functional scenarios but
  produced zero-throughput rounds and process exits at C=8/32. Find the race/lifetime bug before
  any performance claim.
- [ ] **Runtime backend probe/fallback.** Selection is `LEANIN_SHIM=uring` at build time. Add a
  facade with a startup probe (`io_uring_queue_init`, feature flags, seccomp/sysctl), falling back
  to libuv. Keep libuv as the default and portable backend.
- [ ] **C=1 latency experiment.** Best observed is ~0.82× libuv at depth 1; depth-16 is 1.2–1.4×.
  Treat parity at depth 1 as the bar, not a win.

## P3 — compatibility and release

- [ ] **Stock `Std.Http.Server.Handler` adapter in LeanIn.** `Routing.Compat` provides the
  routing-side migration path; LeanIn has no stock-handler adapter of its own.
- [ ] **Release the lifecycle work.** `v0.5.0` contains only the continue-policy hook; deadline,
  scope and timer cancellation are untagged.
- [ ] **Performance record.** Re-run the routing and LeanIO pairs on a settled host with load
  average and a recorded commit; the current tables are provisional.
