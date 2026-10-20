# `async` as the basis: workplan

Status: draft, 2026-10-18. Grounding: milestone 3 of `docs/tokio-workplan.md` (the compiled driver, landed and
measured); `docs/async-vm.md` (the experiment arc and its deleted modules); the review record of the driver
change (error model, red evidence).

## 0. Where things stand

Three models are visible in the tree, and a user can see the seams:

- **`EAsync`/`Task`** — the general task runtime (spawn, await, registry, select, sync), on `Join`-cell
  delivery. This is the *semantic reference* and the measured CPS baseline, and what the controls are written
  against. It is not the advertised authoring surface.
- **`VM`** — the interpreted free machine (`runK`, three continuations: value, ordinary error, transport abort).
  General — any `IO` via `ioE`, raise/catch and abort that span suspensions — but interpreted: `bind` rebuilds
  the tree and the interpreter walks it. This is the
  *escape hatch* for code the compiler cannot express, not the fast path.
- **`async`** — the compiler: a do-body becomes a per-function state machine resumed by raw delivery.
  Proven on the production HTTP driver (`×1.42–1.57` over the CPS driver, SC19/SC20 byte-identical), but a
  **closed per-connection DSL**: six socket effects plus `VM.runAsync`, no spawn, no select, no first-class
  timer. (M1, landed: field types are inferred or rejected with the field named — the `Unit` fallback is
  gone — and every parameter is a threaded field, so the never-rebound silent-constant shape cannot occur.)

The engine is not in question and does not change: the executor (`Sched`/`Runtime` — carriers, pools,
park/wake, timers, the blocking pool) is what machines compile *onto*, exactly as `async`/`await` compiles onto
Tokio's scheduler rather than replacing it.

## 1. The target

One authoring model: a do-body that compiles, with spawn, await, select, timers, channels and sockets as
effects, machine-to-machine composition without the interpreted hop — and the HTTP server as the showcase a
user reads first, benchmarked against Node as a standing comparison. `EAsync` stays as reference semantics and
the controls' harness; `VM` stays as the escape hatch; neither is what the documentation shows a new user.

The trap this plan was ordered around, and M1 closed: the compiler's failure modes were *silent* (a parameter
never rebound stayed a constant, a bare statement never ran, a field type fell back to `Unit`). M1 removed all
three shapes — every parameter threads, bare statements execute as actions, and field types are inferred or
rejected with the field named — so new effects land on a surface that fails loudly where it cannot be right,
rather than multiplying the silent-wrongness surface.

## 2. Milestones

### M1 — Sound authoring: no silent wrongness

- Field types: an ascription or inference succeeds, or the macro **errors with the variable named** — the
  `Unit` fallback goes away.
- Threading: **every parameter is a threaded field** (state 0 carries it, `recurse` passes its current value
  back), replacing the rebound/constant split — the split was the silent-trap shape (a parameter the body
  forgot to rebind stayed a constant with no sign of it, which is how the driver's protocol machine was once
  discarded), and a warning version of it would have fired on the driver's own legitimately-constant
  parameters (`cfg`/`handler`/`onClose`). Chosen over the warning on paired same-session measurement: no
  measurable cost against the instrument's own variance (M1: 77185/107183/79703 rps vs split:
  103789/84952 rps at C=8, spread documented at ±30%).
- Bare statements and destructuring `let`: statements sequence as actions (landed); destructuring `let` is
  rejected with the construct named and the remedy stated (landed).
- **Acceptance**: an uninferable live field (the `Unit`-typed `r` shape) is rejected with the field and
  remedy named; an unrebound parameter (the `m` shape) is *carried* — the generated `step` takes the
  connection alone, pinned by the fixture's own type assertions on `step`'s and `run`'s signatures; bare
  statements execute as actions (the driver's `onClose` path, exercised by SC19/SC20); destructuring `let`
  is rejected with the construct named. `DefuncEcho`'s machines and the driver compile unchanged, and
  SC19/SC20 stay byte-identical.
- **Evidence**: `tests/async-diagnostics.sh` (two rejections grepped for their named diagnostics, one
  positive machine whose generated signatures are asserted in the file); `nix develop -c lake build` green;
  SC19/SC20 green; the paired measurement above.

### M2 — Composition: machines awaiting machines

- The machine call, landed: any `*.run` application in an `await` suspends on the callee — but only after the
  classifier proves the callee is a compiled machine's `run` (its `.St` exists in the environment), that all
  ordinary arguments are supplied, and that its last parameter is a function — each violation a named
  diagnostic. The generator passes the caller's continuation as that last parameter: the callee invokes its
  `onDone` and `halt`s, resuming the caller by raw delivery with no cell and no interpreted `VM` in the path.
- **Acceptance**: a parent machine awaits a child machine over a real socket; the composed stream arrives in
  order, the parent's resend proving the child's `onDone` resumed it; and the resume lands on the child's own
  completion thread — in the single-carrier driver, accept loop, connection effects and resume all read one
  thread, with the harness's dedicated-task tid as the live control that the detector distinguishes threads.
  The no-cell fact is structural (the generator passes the caller's continuation as the callee's last
  parameter — the expansion names no cell) and costed by the benchmark below; a single-carrier harness cannot
  distinguish cell from no-cell by thread, and the multi-carrier entry does not serve (the recorded
  `runCarriers` defect), so that distinction is stated as a limit, not claimed.
- **Evidence**: SC23 (`tests/executor-contract.md`, with its shell fixture): the composed byte stream in
  order with the read's own bound recorded (`bounded == no`, SC20-O3's idiom) and the tid records above. The
  direct-continuation shape was chosen over cell-parking
  before implementation and the reading confirms it costs nothing: same-session C=8, one machine call per
  request — **197322 rps** against 195801 rps for the same loop with the write inline and 182624 rps for the
  interpreted `VM` echo (the call is within noise of free; the interpreted hop costs ~7% — 1 −
  182624/195801 ≈ 6.7%). Landed with `halt` as the return terminal and typed `await` (`let x : T := await e`,
  whose ascription wins over effect inference — including on the close).

### M3 — Time as an effect

- **Landed**: `Io.sleepRaw` (one timer per suspension on the injected clock's `schedule`) as a classifier
  effect; the deadline half is the already-landed `recvTimeoutRaw`, exercised here at the machine level rather
  than through the HTTP driver. A general `timeout` over arbitrary suspensions is `select`, which is M4.
- **Acceptance met**: SC24 — a machine that sleeps between writes (`dl|`) and one whose operation loses a
  timeout race (`st|`), both driven by `HarnessClock`, each asserted at the harness clock's stated instant
  (`at == delay`, `at == stall`) with the same client-read detector reporting bytes in one clause and none in
  the other.
- **Two runtime facts the milestone surfaced**: a harness instant lives in the clock's own list, not libuv's
  wheel, so the thread that must reach it is the *driver* parked on the executor's condvar — `HarnessClock.clockWithWake`
  composes the schedule with the inject nudge such a park needs (a bare `npUvWheelWake` would end the loop
  pump's park, not the driver's); and pattern-derived liveness was collecting constructor idents (a phantom
  `ok` state field from `.ok ()` terms) — fixed by skipping receiver-less dot heads in `usedNames`, skipping
  application heads and dot heads in `patBoundNames`, and binding a suspension's source ascription into the
  binder so a mismatch fails live or dead.
- **Performance reading**: at the virtual clock the stated instants cost nothing in wall time — both clauses
  complete in ~1 ms of live time for a 30 ms virtual instant (the driver advances to the pending instant and
  stops when the run resolves). In production `sleepRaw` pays one wheel push and one wake per suspension —
  the same cost every live timer already pays through the clock's `schedule` — and the harness-only additions
  (a mutex insert and an inject push per arm) never run on the live path.

### M4 — spawn and select

- `spawn`: a machine scheduled onto the executor, awaited through a cell — *superseded design*: the substrate
  was planned as `Task.Async.spawn`; the landed spawner uses the executor's own inject (`sharedPush`) because
  a compiled step carries no `Ctx` route (see the landed note below). The compiled surface is a classifier
  effect with a cell per spawn, never per step.
- `select`/`race`: first-wins over two suspensions (`RawCell.resolve` is already first-wins); the tie rule is
  registration order, as `Task.select` documents.
- **Acceptance**: spawn/join ordering records in the SC1 idiom; a select scenario in the SC16 idiom (winner,
  ready order, loser's fate).
- **Evidence**: one scenario each with fixture; wake rules reconciled with the executor's `poked`/broadcast
  machinery and stated in the decision record.
- **Landed**: a spawner is generated beside every tagged `run` whose last parameter is `(α → IO Unit)`:
  `Foo.spawn push c …` allocates a `RawCell α`, pushes an executor item that runs the child with
  `RawCell.resolve cell` as its `onDone`, and hands the cell back as the handle. The classifier's `.spawn`
  emits the handle bind; `.join` (`RawCell.await h`) is the suspension; `.newCell`/`.resolve` expose the
  cell primitives directly, so a machine can stage deterministic completions. `select` compiles to
  `LeanIn.Runtime.selectRaw h0 h1`, first-wins over two cells with registration order as the tie rule (the
  `won` flag makes the loser's later resolution a no-op). The spawn's substrate is the executor's own inject
  (`Runtime.sharedPush`) rather than `Task.Async.spawn`, which needs a `Ctx` route a compiled step does not
  carry; the wake is the same push a parked driver is woken by, so no new wake rule was introduced.
- **Wake rule**: spawn adds no wake path — it calls the same inject every other push uses. SC25's completion
  assertion reaches a push that does not reach the executor (a through-reach reading, not a wake-only one,
  because the parent enqueues while running and a driver drains queued work before parking); the parked-wake
  rule is `sharedPush`'s, exercised by SC2 (an injected completion waking a waiting `blockOn`), with SC18's
  non-carrier wake beside it, rather than re-proved here.
- **Scenario evidence**: SC25 (`defuncEcho … spawn`) serves identical children with two join orders and
  answers `BBBAAA` for `0` and `AAABBB` for `1` — a completion-order collector would give one order in both,
  and a value-sorting one cannot satisfy both — under a client bound that never fires; the same client
  against a silent `cps` connection under a 1 s bound exits 124 as the detector's control. SC26
  (`defuncEcho … select`) answers `A1one` (the cell resolved before the select wins with its own payload
  even though it registered second, and the loser's later resolution produces no second resume) and
  `B0zero` (both cells resolved before the select: registration order wins, with its payload).
- **Performance reading** (a separate client loop, not fixture output: client-side wall clock over loopback,
  this host, one session's readings; instrument and limits stated): one connection's service for `spawn` is 39 µs and for `select` 49 µs over 300 sequential
  connections, against 14 µs per echoed request inside one connection for the plain loop echo. The
  connection figures include accept/churn, so they are not a spawn-cost isolation: the attributable spawn
  work per connection is one cell allocation, two executor pushes, two resolutions and one park/resume; the
  select work is two cell allocations, two resolutions, a select registration and a winner resume. Both are
  connection-dominated on loopback and say nothing about per-request spawn cost, which needs a machine that
  spawns within a served exchange.

### M5 — The server surface, and the showcase

- `acceptRaw`: accept as a raw effect (the substrate is `arrive`/parked accept in `Io.lean`); `serve`
  compiled as a machine, so the accept loop joins the connection loop in one model.
- The showcase: an example server that reads like Tokio's hello-world — bind, `serve`, a handler — with the
  HTTP server behind it, and `bench/threeway.sh` wired into CI as the standing Node comparison.
- The authoring guide: a `docs/` page naming what compiles, what falls back, and what the limits are (the
  closed effect set as it stands per milestone, the same-type constraint, the threading rule).
- **Acceptance**: the example builds and serves; CI runs the threeway and the contract suite on the example's
  path; the guide's every command executes (the repo's documentation rule).
- **Evidence**: the example's scenario, the CI job, the guide's commands run and recorded.
- **Landed**: `Io.acceptRaw l push` is the callback form of accept — an arrived connection resumes in the
  step, a parked accept resumes through the app's inject when the loop delivers — so a compiled accept loop
  needs no stock task. The machine syntax's first parameter is now typed by its declaration rather than fixed
  to `Conn`, which lets an accept loop carry its listener; connection loops are unchanged. `lean_exe hello`
  (`LeanIn/Exe/Hello.lean`) binds, serves and answers with three machines — `helloConn`, `helloServe`
  (accept, spawn per connection, recurse), and the per-connection spawn as an executor item. `SC27` drives
  it over loopback: two sequential connections each read the pinned HTTP response byte-exactly (`cmp`
  against a byte file), with no socket bound on the read, the invocation's 20 s watchdog as the completion
  detector, and a silent connection under a 1 s client bound as the detector's control.
- **Guide**: `docs/async-guide.md` names the effect set, the threading and ascription rules, the loud
  failures, the runtime you need, and the limits; every command it displays names its own inputs.
- **CI**: the scenario job's list runs through `SC27`, and the same job runs `bench/threeway.sh` (one level)
  after the scenario loop, because the comparison needs the `server`/`stdServer` binaries and libuv, not a
  ratio gate.

## 3. What each model is for, after this lands

- **Executor / `Sched` / `Runtime`** — the engine. Unchanged by this plan; machines compile onto it.
- **`async`** — the advertised authoring surface for concurrent code.
- **`VM`** — the interpreted escape hatch: dynamic effects, code the compiler cannot express, and the
  handler shape for suspension-heavy user logic until M2/M4 cover it.
- **`EAsync`/`Task`** — the reference semantics, the controls' harness, and the CPS baseline in the
  measurements. Kept on purpose: it is what the compiler's output is checked against, and it is the executor's
  own substrate (`spawn`/`Registry`/`select` in M4 are built from it).

## 4. Risks and open designs

- **M2's resume shape.** A direct call of the callee's `step` from the caller's continuation is cheapest but
  couples the machines' state layouts; a cell-per-call is uniform. Decide on the microbenchmark's evidence
  before committing the surface.
- **M4's wake rules.** A spawned machine completing on a carrier must wake the right parker; the executor's
  per-worker `poked` flag and broadcast are the standing mechanism (see AGENTS.md's wake-rule summary), and
  the scenario must show no lost wakeup, as SC1 does for the leaf seam.
- **Field typing.** M1 chooses *loud rejection* over the `Unit` fallback. Full elaboration-time typing is the
  larger change and is only taken if the ascription noise proves to bite in the M2/M4 work; the decision and
  its reason are recorded.
- **Accept fairness.** A raw accept effect changes the accept loop's wake shape versus the current `Join`
  accept; M5's scenario must cover admitted-order and stop-drain behavior, not only throughput.

## 5. What stays absent

No green threads, no fairness or priority guarantees beyond the LIFO allowance bound, no indexed
heterogeneous `VM` (the predicativity wall stands — the compiler sidesteps it by emitting code rather than
data), no general cancellation of a running handler (W5/W7's item, unchanged). What the streaming driver does
have is a request scope over **peer-I/O failure** only: a failed body read, a stall, a peer close mid-body or a
failed response send aborts the request and closes its connection (D23); a handler parked on anything else is
still not cancelled.
