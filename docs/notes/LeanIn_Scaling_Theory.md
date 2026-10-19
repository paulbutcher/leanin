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

**The sweep landed, with the driver owning the deadline.** The design that works needs no timer at all: a read
writes one slot (connection → deadline), its completion erases it, and `driveOnce` folds the earliest slot
deadline into its own poll timeout and sweeps expired slots at the top of each iteration. The clock carries a
`swept` capability: the live clock is swept, a harness clock keeps the armed instant it must retire exactly.

Three integration defects were found and fixed on the way:

1. Scheduling a timer from the read path hung SC20's suspending-handler clause — removed by the design, which
   schedules nothing on the request path.
2. The driver's idle test counted only the Join-based parked table, so a **raw operation outstanding with no
   deadline** (the response write) made it condvar-park while the loop still owed the completion; the wake for
   a later submission reaches the loop, not the executor. The test now also requires no raw operation, with a
   1 ms poll while one is outstanding.
3. The machine syntax rejects a typed bind of an `if` of two awaits; the driver branches explicitly.

**Measured, same session, server core 1 / client core 2, three runs each:**

| arm | rps | µs CPU/request | p50 |
|---|---|---|---|
| before | 112.4 / 111.3 / 115.4 k | 8.39 / 8.59 / 8.37 | 63 / 65 / 63 µs |
| **swept deadline** | **120.4 / 128.0 / 132.7 k** | **7.66 / 7.44 / 7.28** | **58 / 56 / 55 µs** |

That is ~1.0 µs less CPU per request (+12 % throughput, p50 −12 %). The pinned threeway in the fast host state
reads ~0.94× Node at C=8 and ~0.81× at C=32; repeated medians, not single runs, are the number to quote.

**C-growth attributed (callgrind, unprivileged: per-function instruction counts).** The driver was profiled
under `valgrind --tool=callgrind` with a real client at C=8 and C=32; instructions per request are 10,599 and
12,025 (+13.5 %, matching the +18 % CPU time). Per request:

| component | C=8 | C=32 | change |
|---|---|---|---|
| `dispatch` | 8,934 | 11,306 | +2,372 |
| `opDone` (write completion) | 2,178 | 3,432 | +1,254 (×1.6) |
| `lean_mark_mt` (GC marking) | 1,015 | 2,209 | +1,194 (×2.2) |
| `dec_ref_cold` (refcount) | 2,232 | 2,624 | +392 |
| `pump` | 4,246 | 4,132 | flat |
| parse/step/send | ~2,500 | ~2,510 | flat |

So the growth is **not protocol work**: it is GC marking (×2.2, the live set grows with the connection count) and
the write-completion path (×1.6, whose cause is not yet isolated). GC and refcounting together are ~44 % of
instructions at C=32; `pump` is ~34 % and flat across levels.

**Serious profiling with `perf` (after the host's `perf_event_paranoid` was lowered and the generic 6.17 tools
package installed).** Sampled profiles at C=8 and C=32, server pinned, under load:

| symbol | C=8 | C=32 |
|---|---|---|
| `lean_dec_ref_cold` | 24.7 % | 27.0 % |
| `lean_mark_mt` (GC) | 5.6 % | 10.1 % |
| `lean_copy_expand_array` | 3.2 % | 10.4 % |
| `mi_free` | 4.3 % | 3.5 % |
| `lean_alloc_small_object_core` | 3.3 % | 2.7 % |
| H1 `findLF` loop | 1.9 % | 1.3 % |
| mutex lock/unlock | 3.6 % | 2.7 % |

The C-growth is **`copy_expand_array` (×3.2) and GC marking (×1.8)**. The call graph attributes the array copy
entirely to `Std.DHashMap` insert/erase in `registerRaw`/`rawResume` — the aliasing shape: the map is read out of
its cell for mutation. **Taking the map out of the cell before mutating it (the same discipline that fixed the
slot array) made no measurable difference** (C=8 7.08–7.16 vs 7.04–7.09 µs; C=32 8.26–8.29 vs 8.14–8.27), so the
copy is inherent to the map's structure or does not translate to wall time. Allocation and refcount remain the
dominant, growth-bearing term (~37 % at C=8, ~44 % at C=32), which is the frame/state-representation direction.

**Earlier profiling method (callgrind, retained for reference).** `perf` is blocked (`perf_event_paranoid = 4`), so the workable
instrument is callgrind on a **finite** workload: `server <port> quiet count=N` serves exactly N connections and
exits, so callgrind writes one complete profile; a `count=1` run gives the startup constant, and
`(Ir − startup) / requests` is the per-request instruction count. On the committed driver: 1,577 M Ir for 27,992
requests minus 206 M startup = **~49,000 Ir/request** (25,300 self). Findings:

- **~51 allocator calls per request** (`mi_malloc` 50.8/req) — the allocation target, now quantified.
- **H1's own loops dominate self-cost**: `repeatM` 1,591 + a `Legacy.Range.forIn` 963 +
  `String.mapAux at H1.Writer.shouldKeepAlive` 486 ≈ 3,000 Ir/request, while `H1.Machine.step` is 161 and
  `parseHeaders` 146. `shouldKeepAlive` case-folds header strings per request; that is a concrete, local fix.
- HashMap internals are ~2 calls per operation (~8/request across read+write registration).
- Inclusive: `dispatch` 77 %, `rawResume` 71 %, `readDone` 57 %, `pump` 37 %, refcount 20 %, `opDone` 19 %.

Callgrind's own `callgrind_control` dumps fragmented the profile (empty totals) and mid-run dumps mismatched the
request count; the finite-workload method is the one to reuse. Self-cost totals parse to ~58 % of the program
total (the format drops some position encodings), so treat self-cost *rankings* as the signal, not the absolute.

**Earlier attempts at allocation counts, recorded so they are not repeated:**

- *Allocation-site counts*: callgrind's `calls=` counts taken from a mid-run dump cover only a slice while the
  client's completed count covers the whole run, and an attempt to gate counting with `--instr-atstart=no` plus
  `callgrind_control -i on/-d` produced implausible totals (≈300 Ir/request). No reliable per-site allocation
  counts were obtained with the available unprivileged tools; the Ir *shares* above remain indicative.
- *Slot arrays for raw registrations*: a first attempt was **catastrophically slower** (9.2 k rps, 10.4 µs
  against 128–135 k, 7.1 µs). The cause was aliasing, not the design: reading the array out of the cell leaves a
  second reference in it, so `set!` copies the whole array per operation. Taking the value out of the cell
  (leaving it empty), updating in place, and putting it back — the discipline a single-carrier runtime allows —
  restores parity exactly: **6.96–7.19 µs at C=8 and 8.15–8.28 at C=32 against the map's 7.04–7.10 and
  8.19–8.43**. No gain, so it was reverted: the hash map's hashing and per-op allocation are not the C-growth
  either. The discipline itself is the reusable lesson — in-place updates are available, but every reference
  held during the update must be removed first.

**Two more local designs measured worse and were reverted, which closes the "shave the protocol path" family:**

- *Byte-built response encoding* (status digits written manually, headers appended into one buffer instead of
  `s!`/`String.join`/`toUTF8`): **~7 % slower at C=8 and C=32** — `ByteArray.append` copies the accumulated buffer
  per piece, so the encoder became quadratic per response. A correct version would need a single preallocated
  buffer or a chunk list joined once, and would still face the measurement bar.
- *Allocation-free literal comparisons plus one-pass header classification* (packed-`Nat` matching for
  `close`/`keep-alive`/`connection`/`content-length`, `Content-Length` and keep-alive decided during parsing):
  **~7 % slower at C=8 and ~8 % at C=32**. The packed comparison costs more per header than the original
  short-circuiting `findSome?` scans, and the single pass visits every header instead of stopping early.

So the profile's named sites (`String.mapAux`, literal allocation, `Range.forIn`) do not translate into wall-time
wins when replaced locally; every micro-change measured parity or worse.

**Wake checks (does I/O wake the loop correctly?).** A missed wake shows up as latency quantised at the poll
timeout, so each shape was measured with the *same client* against Node as the control: busy (20 k requests),
5 ms gaps, and 100 ms idle. LeanIn: p50 11 µs / p99 20 / p99.9 72 busy, p99 1.07 ms gapped, p50 242 µs idle;
Node: p50 12 / p99 61 / **p99.9 2.3 ms** busy, p99 1.27 ms gapped, p50 409 µs idle. Both arms share the tails and
LeanIn's are smaller, so the outliers are client/host scheduling, not a stalled loop. Per-request orchestration is
also ~0 (Deque.pop 0.30/req, every other executor call 0.00), consistent with the raw path resuming inline.

**Carriers, measured two ways — both fail.**

- *Wired and correct, no effect.* With `Runtime.runCarriers` fixed to drive the loop while it waits (the caller
  pumps; `Io.takeover` so one driver), a `carriers=2/3` server serves correctly but reads 130.9–132.9 k at C=8
  and 113.7–116.0 k at C=32 — identical to one carrier. Raw completions resume **inline on the loop thread**, so
  extra carriers execute no connection work.
- *Inject delivery.* Routing raw completions through the executor's inject (so steps run on carriers) is **much
  worse and anti-scaling**: C=8 reads 82 k with two carriers and 79 k with three against 125 k inline, at 2.5–3.3
  µs/request against 0.72. One push and wake per completion costs more than any parallelism gained, and more
  carriers lose more.

Both reverted. Parallelism is not available through the current machinery: one loop thread that must also pump,
and a cross-thread wake per completion. Getting it would need a delivery design that batches completions per
carrier — a project of its own, not a configuration.

**That makes allocation the target, and it revives the supervisor note's direction** with evidence: a state
representation that allocates a constructor per transition feeds both `dec_ref` and the mark phase, and the mark
cost is what grows with connections. The note's fixed-frame proposal should be re-read against this profile
(`docs/notes/LeanIn_Frame_Reuse_Handoff.md`), starting with the measured allocation sites rather than the parser.
The `opDone` growth needs its own attribution next (its lookup is a linear scan of the Join-based parked table;
whether that table holds anything at higher C is unverified).

**Then the pump**: driver minus no-parse is now ~2.3 µs/request, of which `h1bench` attributes 0.41 to parsing.
That is the last per-request item before carriers.

**Measurement hygiene**: two benchmark servers from an interrupted run survived their `kill` and distorted a
round of A/Bs, and the host can carry unrelated load (observed 4.9); check `pgrep` and the load average before
believing any absolute figure, and trust only same-session pairs.

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
