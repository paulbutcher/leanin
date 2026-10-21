# io_uring socket backend (experiment)

Branch: `feature/io-uring-backend`.

`c/neturing.c` is a second implementation of the `np_uv_*` shim contract. It is selected at build time:

```bash
LEANIN_SHIM=uring nix develop -c lake build server
```

With no `LEANIN_SHIM`, `c/netuv.c` (libuv) is built, unchanged. The dev shell provides `liburing` and sets
`LIBRARY_PATH`/`LD_LIBRARY_PATH` for its headers, link and runtime.

## What uses the ring

`accept`, `recv`, `send`, `writev` and `shutdown` are io_uring operations. Completions are drained into the same
`(kind, conn, arg)` queue as before; `np_uv_take` copies the completed byte count. The ring has an eventfd
registered and a `uv_poll` watches it, so the loop still has one parking point.

libuv remains for what it already did well: the cross-thread async wake, the wheel timer's park timeout, and
signal watches. The loop is therefore a hybrid, not a pure io_uring loop: `epoll` still waits on the eventfd,
and timers/signals are libuv handles. Socket readiness is no longer an epoll operation.

Two consequences drove the code:

- A `recv` holds a file reference in io_uring, so `close(2)` alone does not send FIN while a read is
  outstanding. A close cancels the tracked read first and closes on the cancel completion.
- Connections are not libuv handles, so `uv_run` can report no active handles while ring work is outstanding.
  The shim reports a live listener or connection as active.

Write buffers (single and vectored) are copied and retired from a per-connection FIFO on completion.

## Verification

With `LEANIN_SHIM=uring`:

- `SC20`, `SC22`, `SC23`, `SC24`, `SC25`, `SC26`, `SC27` pass.
- `tests/http-stream.sh` passes.
- `controls --runtime-net`, `--raw-registry` (with `NETUV_RAW_CHECK=1`), and `SC10` pass.
- The default libuv build still builds and runs its scenarios.

Not yet ported or exercised: the libuv backend's always-armed read and `MAX_BUF` backpressure; the drain-before-
close path (a close with unread peer data may reset rather than FIN); multishot accept/recv; a pure-io_uring
timer/signal loop; io_uring for filesystem work. `SubmissionQueue` entries are prepared by the loop thread only,
as before; carriers enqueue submissions under the existing mutex.

## Provisional throughput

Paired, interleaved, `server quiet`, `GET /bench`, 5 s per arm, 5 rounds per level, client pinned to CPU 2; the
server was not pinned in this run. `uv` is `/tmp/server-uv` (built without `LEANIN_SHIM`), `uring` is the same
tree with `LEANIN_SHIM=uring`.

| C | uv rps (median) | uring rps (median) | uring / uv |
|---:|---:|---:|---:|
| 1 | 67 934 | 64 967 | 0.956 |
| 8 | 124 155 | 134 089 | 1.079 |
| 32 | 140 549 | 166 247 | 1.123 |

The shape: a small loss at one connection, where per-request orchestration dominates and the ring adds a
submission path; a gain at 8 and 32, where batching and fewer socket syscalls pay. These are provisional — one
host state, no load average recorded, and no repetition after the final buffer-retirement change beyond the
tests above. Do not promote to a performance record without a same-session paired rerun on a settled host.

## Direct-ring experiment sequence (2026-10-21)

E0: a standalone C HTTP keep-alive server, `bench/uring-http.c`, with
`IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN`, multishot accept, batched submission and no
eventfd/epoll. Against the LeanIn libuv `server` on the same `/bench` shape (3 rounds, 3 s, client pinned):
1.14× at C=1, 1.41× at C=8, 1.43× at C=32. That comparison is **confounded**: E0 is a minimal C server, while
`server` carries the Lean runtime and HTTP driver, so it does not isolate epoll from io_uring.

E1: the hybrid shim with the two setup flags and one submit per loop. It passes SC27; measured 0.94× at C=1,
~1.04–1.31× at C=8 and ~1.13× at C=32 against libuv. No C=1 recovery.

E2: multishot accept in the hybrid. SC20/SC22–SC27, http-stream and raw-registry pass. Throughput was
indistinguishable within the run-to-run noise; accept was not the bottleneck at these levels.

E3: multishot recv with a provided buffer ring in the E0 harness. No consistent gain over E0's one-shot recv:
C=1 equal or lower, C=8/C=32 equal within noise. The request path is dominated by response construction,
copying and per-connection orchestration, not recv SQE submission.

Conclusion so far: the ring architecture is sound, but this workload has not shown a stable neturing speedup.
E1/E2 remain as non-regressing improvements; E3 was not ported. A fair next experiment needs a minimal **libuv**
C server with the same parser/response, not the Lean server, and then a zero-copy send path from the provided
buffer before repeating the paired run.

### Fair E0 baseline and SQPOLL (2026-10-21)

`bench/libuv-http.c` is the same minimal HTTP parser/response on libuv C. This removes the Lean-server confound.
Paired, 3 s, 3 rounds, client pinned:

| C | libuv C | uring one-shot | uring multishot recv |
|---:|---:|---:|---:|
| 1 | 84 504–86 757 | 64 982–69 434 | 68 913–69 909 |
| 8 | 208 495–211 089 | 206 294–210 167 | 206 161–211 818 |
| 32 | 173 953–182 659 | 172 987–180 118 | 167 589–178 413 |

So the earlier E0-vs-Lean-server gain was the C server, not the ring. Against the fair libuv C baseline, io_uring
is ~0.8× at C=1 and parity at C=8/32. Multishot recv does not change that shape.

SQPOLL (`IORING_SETUP_SQPOLL | SINGLE_ISSUER`, `sq_thread_idle=1000`; `DEFER_TASKRUN` is rejected in that
combination) measured 63 131 rps at C=1 — no recovery.

Conclusion: for this single-carrier, keep-alive, one-request-in-flight workload, io_uring does not beat epoll.
The remaining levers (SQPOLL, multishot recv, setup flags) are all neutral or negative here. E1/E2 stay in the
opt-in shim as non-regressing experiments; the backend should not be promoted.

### E5: submit-and-wait, and pipelining (the missing shape)

Two corrections changed the conclusion:

1. `io_uring_submit_and_wait(ring, 1)` replaces the separate `submit` + `wait_cqe`. One enter per loop turn.
2. The benchmark shape matters: at depth 1 there is nothing to batch. With `LOAD_PIPE=16` (16 requests in
   flight per connection), the ring has work to amortise.

Paired against the fair `bench/libuv-http.c`, 3 s, 3 rounds:

| C | depth | libuv C | uring `submit_and_wait` |
|---:|---:|---:|---:|
| 1 | 1 | 84.5–86.8k | 68.9k |
| 8 | 1 | 208–211k | ~208k |
| 32 | 1 | 174–183k | ~175k |
| 1 | 16 | 73–175k (unstable) | **279–283k** |
| 8 | 16 | 221–223k | **263–278k** |
| 32 | 16 | 238–249k | **292–294k** |

At depth 16 the ring is ~1.2–1.25× at C=8/32 and clearly ahead at C=1 in this harness. The depth-1 result stands:
there, epoll and one-shot ring are parity or epoll ahead.

Conclusion: the earlier “no speedup” was a wrong-shape and wrong-syscall-pattern test. io_uring is viable for this
server when the workload has pipelined requests and the loop uses one `submit_and_wait` per turn. The Lean shim
still uses the hybrid loop and one-request benchmarks; porting the direct loop + submit-and-wait is the next step,
then re-running the Lean server with `LOAD_PIPE=16`.
