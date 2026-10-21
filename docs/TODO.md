# LeanIn TODO

Open work found while serving lean-routing and LeanIO on LeanIn. Ordered by what blocks production
serving, then what the ports exposed as ergonomics or performance, then backend and release work.

## P0 — lifecycle correctness

- [ ] **Deadline abort on drain.** `serveUntilStopped` stops admission and drains in-flight work, but
  waits indefinitely. Add a grace deadline that cancels what remains and then waits for every
  connection task to settle.
  - Needs: a live-connection registry with close/cancel handles; request-scope cancellation; a
    drain-completion cell and a select against a grace timer.
  - Evidence today: `Runtime.Net.serveUntilStopped`; LeanIO's `ServerHandle.stop` only drains.
- [ ] **Cancellable parked timers.** `VM.sleep` schedules a clock continuation; setting
  `Task.Cancel` disarms the fire but leaves the sleeper parked, and `Io.stop` clears the wheel
  without resolving waiters.
  - Needs: an `onCancel` continuation on wheel entries, and an ambient cancellation scope that
    `sleepE` registers with.
  - Acceptance: a parked 60 s sleep is aborted within a 200 ms deadline; `onExit` runs once; the
    loop returns.
- [ ] **Request/handler scope.** User-triggered cancellation, child cancellation, and exactly-once
  cleanup on scope exit. Transport abort exists; the general scope does not.
  - Depends on the timer cancellation above for parked handlers.
- [ ] **Bound streaming request bodies.** `H1.Limits.maxBody` applies to the buffered driver only.
  A streaming `BodyReader` that calls `readAll` can grow without bound.
  - Needs a byte-count limit shared by buffered and streaming reads, with a typed 413 response.

## P1 — HTTP serving surface

- [ ] **Decoded path/query at the H1 boundary.** `H1.Head` exposes `targetString`; consumers
  re-parse and percent-decode with `Std.Http.RequestTarget.parse?` per request. Add slice-based
  decoded path/query views, and use them from routing to remove the per-request parse.
- [ ] **One continue policy.** `Limits.autoContinue` defaults true and is independent of a
  handler's `onContinue`; a router's decision is ignored unless the config also turns
  `autoContinue` off. Make the policy single and explicit, with a safe default.
- [ ] **General interim responses.** Only `100 Continue` is exposed via `sendContinue`; add a
  general 1xx writer path for `103 Early Hints`.
- [ ] **Multi-carrier serving.** The shipped HTTP entry points are single-carrier; wire a
  multi-carrier accept/connection path and state the affinity rules.
- [ ] **Correct the H1 documentation.** `H1.lean` still says chunked framing and `Expect:
  100-continue` are follow-ups; both are implemented.

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
