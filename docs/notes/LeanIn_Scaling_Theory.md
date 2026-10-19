# Scaling theory: where the next performance comes from

Date: 2026-10-19. Status: hypothesis with measured support, not a conclusion. Written to be acted on and
falsified step by step; each step names its experiment and its acceptance number.

## The measurements this rests on

All rows are from one host (Intel Ultra 7 268V: P-cores 0–3, E-cores 4–7), servers on core 1 and clients on
core 2, with `energy_performance_preference = performance`. The full record is
[`docs/PERFORMANCE.md`](../PERFORMANCE.md) §4; the instrument is `bench/threeway.sh`.

| measurement | value |
|---|---|
| driver, C=8, sequential keep-alive | 114 058 rps; **8.2 µs CPU/request** |
| Node, same shape | 146 999 rps; 6.7 µs CPU/request |
| same compiler, no parse (`lake exe hello … keep`) | 197 070 rps; 4.8 µs CPU/request |
| driver, C=8, 16 requests in flight (`LOAD_PIPE=16`) | **261–269 k rps; 3.6 µs CPU/request** |
| parser alone (`lake exe h1bench`) | 0.41 µs/parse |

Two facts carry the theory:

1. **The serving path is not the deficit.** The no-parse control costs 4.8 µs/request — less than Node's
   *entire* server (6.7 µs incl. parsing). The scheduler, the shim, raw delivery and the syscalls are
   competitive; there is nothing worth chasing there first.
2. **The loop is cheap when work batches.** At 16 in flight the driver does 3.6 µs/request and 2.6× Node's
   pipelined throughput. So the compiled step is not intrinsically expensive; the sequential shape's extra
   ~4.6 µs is per-event overhead (read re-arm, write submission, park/wake), which batching amortises.

The gap to Node (8.2 vs 6.7) was first attributed to the 3.4 µs of parse + pump + framing + handler that the
no-parse control does not pay. **The experiment log below corrected that**: most of the 3.4 µs is the per-read
deadline machinery, not the pump.

## Experiment log (2026-10-19): the deadline, not the pump

Measured by A/B variants of `server` under the pinned method above, then discarded (each variant is a
measurement artefact, not a candidate to keep):

| variant | rps | µs CPU/request |
|---|---|---|
| stock | 107–117 k | 8.18–8.86 |
| **timer never armed** (mutex, cancel token and closures still allocated) | 126–131 k | **7.30–7.56** |
| **deadline removed entirely** | 132–145 k | **6.48–7.16** |
| Node, same method | 142–145 k | 6.63–6.74 |

Neither the wheel's size (a 50 ms stall is no faster) nor its inert fires (a one-hour stall is no faster) moves
the number, so the cost is the **registration path**: `timerPending` push, the driver's drain into the
`TreeMap`, the wheel insert, plus the per-read mutex, cancel token and closures. Roughly **1.2 µs is timer
registration and ~0.5 µs the rest of the deadline's bookkeeping**.

**A sweep prototype reached the target and exposed a defect.** A per-connection slot plus one self-rearming
20 ms sweep read **135.1–135.7 k rps at 7.05–7.13 µs/request, p50 53 µs** (stock 117 k / 8.2 µs / 62 µs) —
Node's throughput within ~5 %, on the same core. But SC20's second clause — a handler that suspends 1 ms and
then raises — hangs under the sweep: the request's read is armed and never completes, while the same scenario
passes with the sweep disabled. Gating the arm on an active driver did not fix it; the interaction is with the
loop's stop/restart between scenario clauses or the sweep's timer chain, and the root cause is open. The
prototype was reverted from the tree.

**So the next step is not the pump.** It is to land a deadline whose request path costs a slot write and nothing
else — either by fixing the sweep above, or by reusing per-connection timer/mutex/cancel objects and replacing
one wheel entry in place — with SC20 and the pinned threeway as the gate. The pump's own share (parse 0.41 µs
from `h1bench`; encode, appends and handler not yet separated) is the step after that.

## The theory

**Most probable path to better scaling: cut the per-request protocol cost, then the per-event I/O cost; do not
start with parallelism.**

The single carrier is saturated (95–100 % of one P-core) but it is saturated doing work that is ~40 % avoidable.
At 8.2 µs/request one core caps near 120 k rps; at Node's 6.7 µs it caps near 150 k; at the batched 3.6 µs it
caps near 275 k. Reaching the batched cost in the sequential shape would put throughput at or above Node at
every connection count while staying on one thread — no carrier work, no delivery redesign.

### Step 1 — the pump (largest, lowest-risk win)

Per request the driver runs the `H1.Machine` through the `pump` in `LeanIn/Runtime/Http.lean` to an
`endHeaders`, accumulating output with `acc ++ step.output.data`, scanning `step.events` for the handler event,
building a `PumpResult` structure, then encoding the response head and `sendData`. Parsing is 0.41 µs of the
3.4; the rest is this loop's allocations and scans.

- **Experiment**: a microbenchmark that runs `pump` over a fixed complete request with a pure handler, N times,
  reporting ns/request and steps/request; then split it into (a) `H1.Machine.step` only, (b) steps + output
  accumulation, (c) full pump with handler. Acceptance: the sum of parts explains the 3.4 µs.
- **Fix direction**: accumulate output without a per-step append (a single preallocated buffer or a builder),
  avoid the per-step event scan (fold the scan into the step loop), avoid allocating the stop result where a
  tuple/reuse will do, and reuse the response encoding. Each change is measured by the same microbenchmark and
  then by the pinned threeway.
- **Acceptance**: driver per-request CPU at C=8 falls from 8.2 µs toward ~5.5 µs; C=8 throughput rises above
  140 k rps; the threeway shows ≥ 1.0× Node at C=8 and C=32.

### Step 2 — the per-event I/O path (armed reads, inline writes)

At depth 1 the syscall counts per request are ~1.25 reads, ~1.25 writes and ~0.95 `epoll_ctl`; at depth 16 they
are ~0.16 each. The `epoll_ctl` is the shim's per-read arm/disarm (`uv_read_start` at each submission,
`uv_read_stop` after each read in `c/netuv.c`), and every write goes through the submission queue even when the
submitter is the loop thread.

- **Experiment A (armed reads)**: keep the read armed, buffer inbound chunks per connection, let `np_uv_read`
  claim from the buffer or park, disarm only when the buffer cap is reached. Build one binary in a scratch copy
  and A/B it against the current binary with the same pinned method.
- **Experiment B (inline write)**: when `np_uv_write` is called on the loop thread, try the write directly and
  queue only an unfinished remainder, preserving ordering with any queued write.
- **Acceptance**: step 1's threeway table improves by ≥ 10 % at C=8 beyond step 1 alone; p50 at C=8 falls.
  If either A or B moves nothing outside the ±30 % spread, drop it and say so.

This is also what Tokio and libuv do, and the mechanisms are readable in `Vendor/tokio/src/runtime/park.rs`
(a park that consumes a pending notification without a syscall), `runtime/io/driver.rs` (`turn`/busy batch) and
`ScheduledIo`'s readiness atomic; in libuv, an armed read handle that stops only on demand, and `uv_try_write`.

### Step 3 — carriers (only if steps 1–2 leave a ceiling to lift)

Parallelism does not help until one thread is no longer enough. The written record is that `Runtime.runCarriers`
does not serve (`LeanIn/Exe/Server.lean`, beside the accept loop): the caller waits on a cell without pumping,
so libuv timers and accepts never fire. The design that would fix it is a dedicated loop thread that only
pumps, completions delivered through the inject to worker carriers, and accept driven by the listener's arrival
cell rather than the polling sleep. That is a delivery and accept-loop redesign with its own correctness
surface (the wake rules in `docs/tokio-map.md` and the scenarios SC1/SC2/SC18), and it is worth starting only
when a single carrier at its measured cost is the binding constraint — i.e. after step 1 and probably step 2.

## What not to do, and why

- **Frame reuse** (`docs/notes/LeanIn_Frame_Reuse_Handoff.md`): the mechanism is real and measured — a unique
  transition reuses its frame and costs ~2 ns against ~13 ns for an allocating one — but at ~100 µs request
  latency and a few dozen transitions per request it is a fraction of a percent. Our generated states are
  different constructors per state, so the representation would have to change first. Parked as a note, not a
  plan.
- **Micro-optimising the serving path**: it is already cheaper than Node's whole server (4.8 vs 6.7 µs). Work
  there cannot close the gap that parse/pump opens.
- **Acting on unpinned benchmark rows**: an unpinned client on this host lands on P- or E-cores and moves rows
  by up to 50 %. The 0.52× figure once published was that artifact; the controlled figure is 0.70×. All
  decisions go through the pinned instrument.

## Measurement doctrine for the next rounds

1. Pin server and client to distinct P-cores (`THREEWAY_SERVER_CPU`/`THREEWAY_CLIENT_CPU`), set
   `energy_performance_preference` to `performance`, state the load average.
2. Report CPU per request from `/proc/<pid>/stat` deltas over a fixed window as well as rps — rps alone cannot
   tell a cheaper request from a luckier run.
3. Use `LOAD_PIPE` to separate per-request cost from round-trip serialization when the question is about the
   request, not the shape.
4. Three repeats, medians, and the ±30 % spread in mind; a change smaller than that is not yet a result.
5. Every optimisation lands only with the threeway table before and after, taken in the same session.
