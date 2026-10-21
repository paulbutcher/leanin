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
