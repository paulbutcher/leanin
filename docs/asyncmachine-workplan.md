# `asyncMachine` as the basis: workplan

Status: draft, 2026-10-18. Grounding: milestone 3 of `docs/tokio-workplan.md` (the compiled driver, landed and
measured); `docs/async-vm.md` (the experiment arc and its deleted modules); the review record of the driver
change (error model, red evidence).

## 0. Where things stand

Three models are visible in the tree, and a user can see the seams:

- **`EAsync`/`Task`** — the general task runtime (spawn, await, registry, select, sync), on `Join`-cell
  delivery. This is the *semantic reference* and the measured CPS baseline, and what the controls are written
  against. It is not the advertised authoring surface.
- **`VM`** — the interpreted free machine (`runK`, two-continuation). General — any `IO` via `ioE`, raise/catch
  that spans suspensions — but interpreted: `bind` rebuilds the tree and the interpreter walks it. This is the
  *escape hatch* for code the compiler cannot express, not the fast path.
- **`asyncMachine`** — the compiler: a do-body becomes a per-function state machine resumed by raw delivery.
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
- **Evidence**: `tests/asyncmachine-diagnostics.sh` (two rejections grepped for their named diagnostics, one
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
  order with the read's own bound recorded (`bounded == no`, SC20-O3's idiom), the tid records above, a staged
  behavior red (`onDone` dropped ⇒ `bounded=yes`, only the first echo arrives — the scenario's own assertion)
  and the pre-M2 surface rejection both observed. The direct-continuation shape was chosen over cell-parking
  before implementation and the reading confirms it costs nothing: same-session C=8, one machine call per
  request — **197322 rps** against 195801 rps for the same loop with the write inline and 182624 rps for the
  interpreted `VM` echo (the call is within noise of free; the interpreted hop costs ~7% — 1 −
  182624/195801 ≈ 6.7%). Landed with `halt` as the return terminal and typed `await` (`let x : T := await e`,
  whose ascription wins over effect inference — including on the close).

### M3 — Time as an effect

- `sleepRaw` and `timeout` as classifier effects, on the injected `Clock` (the shape `VM.sleep` already
  proves; harness-driven clocks keep scenarios deterministic).
- **Acceptance**: a machine that sleeps between writes, and a machine whose operation loses a timeout race,
  both driven by `HarnessClock` with stated-instant assertions in the SC20-O3 idiom (`at == stall`).
- **Evidence**: scenario + fixture; the harness clock drives every assertion, no live timing.

### M4 — spawn and select

- `spawn`: a machine scheduled onto the executor, awaited through a cell — the substrate is the existing
  `Task.Async.spawn` machinery; the compiled surface is a classifier effect with a cell per spawn, never per
  step.
- `select`/`race`: first-wins over two suspensions (`RawCell.resolve` is already first-wins); the tie rule is
  registration order, as `Task.select` documents.
- **Acceptance**: spawn/join ordering records in the SC1 idiom; a select scenario in the SC16 idiom (winner,
  ready order, loser's fate).
- **Evidence**: one scenario each with fixture; wake rules reconciled with the executor's `poked`/broadcast
  machinery and stated in the decision record.

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

## 3. What each model is for, after this lands

- **Executor / `Sched` / `Runtime`** — the engine. Unchanged by this plan; machines compile onto it.
- **`asyncMachine`** — the advertised authoring surface for concurrent code.
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
data), no cancellation of a running handler (W5/W7's item, unchanged).
