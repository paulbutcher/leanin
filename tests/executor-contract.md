# The single-carrier executor — behaviour checks

The executor's externally visible promises, checked at its public boundary: the `controls`
executable and an independent pure-model oracle. Nothing here reaches a private function of the
executor. Each check drives the boundary and asserts on the records it produced.

Run one check at a time, from the repository root:

```sh
nix develop -c bash tests/executor-contract.sh SC1
nix develop -c bash tests/executor-contract.sh SC2
nix develop -c bash tests/executor-contract.sh SC3
nix develop -c bash tests/executor-contract.sh SC4
nix develop -c bash tests/executor-contract.sh SC5
```

The fixture is `tests/executor-contract.sh`; the oracle is `tests/ModelOracle.lean`. The shell acts
as the external executable client — its `When` is always an invocation of `controls` and/or the
oracle, never an internal call — and the oracle runs the pure model (`LeanIn.Model.Pool`,
`LeanIn.Model.Scheduler`) so the comparison's expected side is computed rather than written down.

## Records

The `controls` executable reports each executor observation as one line on stdout:

| record | fields |
|---|---|
| `exec\|single\|caller=<tid>\|body=<tid>\|sibling=<tid>\|waker=<tid>\|result=<value>\|order=<events>` | the thread ids of the invoking caller, the awaited task's body, the sibling that must progress on that same caller and the native completion waker of the one observed `blockOn`; the body's returned value; and the events the client recorded for that await, in the order it recorded them |
| `exec\|park\|before=<n>\|after=<n>\|observed=<events>\|queued=<ids>\|delivered=<ids>\|remaining=<n>` | the number of times the pending work completed in each event order, the observed wake events, the ready identities staged before shutdown, the identities whose bodies shutdown actually completed, and the work it left queued |
| `exec\|queue\|staged=<ids>\|phase=<events>\|fifo=<ids>\|lifo=<ids>\|flush=<ids>\|slotBefore=<count:id entries>\|delivered=<ids>\|remaining=<n>` | the identities the client staged at the public queue and scheduling operations, in the order it staged them; the client's own phase events, in the order it recorded them at its actions; the first-phase take receipts of the batch that crossed the ring's capacity; the receipts taken from the LIFO slot; the second-phase receipts after the allowance flushed a pending continuation; the scheduler's own LIFO-slot observation before each of those decisions, keyed by poll count; the identities whose bodies actually ran; and the work left queued |
| `exec\|trace\|<canonical operation record>` | one implementation operation record from the fixed script |
| `exec\|replay\|seed=<seed>\|<canonical trace>` | the canonical trace of one replay of a seed and script |

`staged`, `fifo`, `lifo`, `flush`, `queued` and `delivered` are bracketed comma-separated identity
lists, `[31,32]`; `slotBefore` is a bracketed comma-separated list of `count:id` entries,
`[0:400,1:401]`, each the poll count and the identity the scheduler's LIFO slot held at that
decision. `queued` and `delivered` are the ready identities the client staged before shutdown and the
identities whose bodies shutdown actually completed; each is read as a multiset: the order the bodies
happened to finish in does not matter, while a repeated, missing, unknown or extra id does, and the
count in `remaining` is never a substitute for the identities themselves. `staged` is read as a
multiset for the same reason — the order the bodies ran in is the client's, not the claim — while
`phase` and `order`/`observed` are bare comma-separated event streams, `batch-drained,tick-start`, read
as ordered sequences.
`fifo`, `lifo`, `flush` and `slotBefore` are receipt *sequences*: there the order is the assertion, so
a repeated, missing, unknown or extra entry fails and so does the same entries in another order.
`fifo` and `flush` are also separate phase boundaries: `fifo` carries only the first phase's
receipts and `flush` only the second phase's, so an identity staged into the wrong phase fails its
sequence even when every staged identity is eventually delivered.

A canonical operation record is `op=<name>|pos=<position>|task=<identity>|out=<outcome>`; a canonical
trace is those records joined with `;`, with no leading, trailing or doubled separator. Thread ids,
elapsed time and unrelated stdout are excluded from a canonical trace. The oracle prints one
`model|trace|<canonical operation record>` per step.

The `out` field is the transaction's own outcome, taken from the model:

| `out` | operation |
|---|---|
| `inflight<n>` | a submit or an external enqueue; `n` is the work the pool holds afterwards |
| `taken<n>` | a take that returned a task; `n` is the pool's total taken afterwards |
| `parked<n>` | a park that was granted; `n` is the number of parked carriers afterwards |
| `none` | the operation changed nothing: a park refused while work was held, or a take that found nothing |

The `order` field of an `exec|single|` record lists the events the client recorded for that one await,
each appended by the actor that caused it where it occurred, in the order it occurred:

| event | when the client recorded it |
|---|---|
| `await-registered` | the awaiter registered its continuation and yielded |
| `sibling-done` | the sibling body finished on the invoking caller |
| `gate-released` | the sibling released the fake completion's gate |
| `await-completed` | the awaiter resumed on that caller with its value |

The complete stream is `await-registered,sibling-done,gate-released,await-completed`, so the sibling's
progress precedes the gate release and no event is missing, doubled or unknown. Nothing retypes that
stream from a desired result, and no elapsed time decides the order: the gate is a mutex/condvar
handshake between the sibling and the fake completion.

`observed=<events>` is a comma-separated list of the wake events the client observed, in the order it
observed them:

| event | observation |
|---|---|
| `pre-notify=emitted-before-park` | in the notification-first order, the producer emitted before the carrier parked |
| `pre-notify=completed` | the notification-first wait completed |
| `parked-first=parked` | the carrier had parked before the producer acted |
| `producer=emitted-after-park` | the producer emitted only after that park |
| `parked-first=completed` | the parked-first wait completed |
| `drain=0` | shutdown left no queued work |

These positions are the evidence a check reads. Nothing measures elapsed time to establish a
relation, and the harness watchdog that bounds an invocation is not evidence either: an invocation
that never returns is reported as a defect of the invocation, never as a failure or a pass of a
check.

A check requires exactly one `exec|single|`, `exec|park|`, `exec|queue|` and `exec|replay|` record per
invocation, and as many `exec|trace|` records as the script has steps. Records are parsed by named
key: a key that is absent, repeated or empty fails the check rather than resolving to another field's
value.

A check fails when a record is absent, repeated, malformed, or relationally false, and reports the
check's own `Then` text. A failure before the check's assertion — the executable did not run, the
library did not build, the oracle produced nothing, an invocation never returned — is reported
separately as a setup error.

## The fixed script

Both the executor's trace and the oracle advance the same ordered operations, over the same task
identities, at the same input positions. Every step is one *modelled transaction* rather than a change
to one model at a time: a submit or an external enqueue advances both the pool's `submit` and the
scheduler's `enqueue`; a take that returns a task advances both the pool's `take` and the scheduler's
`take`; a take that finds nothing advances neither. The scheduler's work count and the pool's held
work are then the same quantity after every step, so the two sides' outcomes refer to the same work
rather than to two independent counters, and the two parks mean what they say — refused while two
items are held, granted once both have been taken.

| pos | operation |
|---|---|
| 0 | submit task 0 |
| 1 | submit task 1 |
| 2 | park, with two items held |
| 3 | take task 0 |
| 4 | take task 1 |
| 5 | park, with nothing held |
| 6 | external enqueue task 2, which unparks the carrier |
| 7 | take task 2 |
| 8 | take, with nothing held |

______________________________________________________________________

### SC1 — the awaiter yields to a sibling on the invoking caller before the gated wake

**Actor.** A Lean executable client of LeanIn.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC1`, which invokes
`lake exe controls --executor-single`.

**Given.** An awaiter whose native completion is held behind a synchronized gate — a mutex/condvar
handshake, not a timer — and a sibling task that must execute on the invoking caller and release that
gate. Until the sibling runs, the fake completion cannot fire.

**When.** The client drives `blockOn`.

**Then.** There is exactly one `exec|single|` record, and its fields are exactly `caller`, `body`,
`sibling`, `waker`, `result` and `order` in that order with nonempty values, so every value is bound
from one parsed invocation rather than from anywhere it appears. In that record `body` equals `caller`
and `sibling` equals `caller` — the awaited body and the sibling both ran on the invoking caller's
thread — `waker` differs from `caller`, `result` is `7`, and `order` is the complete recorded stream
`await-registered,sibling-done,gate-released,await-completed`, in which the sibling's progress
precedes the gate release.

The same order detector is held to its own control inside that invocation: it accepts that complete
stream and rejects two near misses — the same events with the gate released before the sibling
progressed, and the stream a blocking await would leave, in which the sibling never progresses at all.
Those near misses are built from event names alone, never from the executor's output, and a control
that does not hold is a fixture defect reported separately from the `Then`. A record that shows a
value returning with no sibling progress has not shown that the awaiter yielded.

**Why.** An await that blocks the carrier returns the right value on the right thread and still
starves every sibling behind it; the executor's nonblocking claim is that the awaiter suspends and
the caller's own carrier runs the sibling, and the only evidence of that at this boundary is the
sibling's progress recorded before the wake.

______________________________________________________________________

### SC2 — an injected completion wakes a waiting `blockOn`, and shutdown delivers the staged work once

**Actor.** A Lean executable client whose injected completion wakes a waiting `blockOn`, and whose
shutdown drains ready work.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC2`, which invokes
`lake exe controls --executor-park`.

**Given.** A synchronized fake completion producer that uses a native `Task` only as a waker and two
separate event orders — notification before the waiter parks, and a waiter truly parked before
notification — and, staged ready before shutdown, two known queued identities, `31` and `32`.

**When.** The client injects the events and calls shutdown.

**Then.** In the one `exec|park|` record, `before` and `after` are each `1` — the pending work
completes exactly once in *both* orders — and `observed` reports, in the order the client observed
them, `pre-notify=emitted-before-park` before `pre-notify=completed`, and `parked-first=parked`
before `producer=emitted-after-park` before `parked-first=completed`, together with `drain=0` for a
shutdown that left no queued work. The parked-first completion is thus preceded by the observation
that the carrier had parked and that the producer emitted only afterwards; that order of observations
is the affirmative control, not a timing claim, and the harness watchdog only bounds a hang.

The staged work, not the count, is what the shutdown claim rests on. `queued` is the client's
pre-shutdown staging receipt and `delivered` is the receipts of the bodies shutdown actually ran;
each is read as a multiset of identities and must be exactly `[31,32]`, so a duplicate `31` with `32`
missing, or an empty `delivered` beside a `remaining` of `0`, fails the `Then` rather than passing on
the count. `remaining` must be `0` as well, and it only corroborates the receipts: it can never stand
in for them.

That delivery comparison is held to its own control inside the same invocation: the detector accepts
the staged pair — `[31,32]` and the same identities in the other order — and rejects both an empty
delivery beside `remaining=0` and a duplicated `31` with `32` missing beside `remaining=0`. The near
misses are written from the staging alone, never taken from the executor's receipts, and a control
that does not hold is a fixture defect reported separately from the `Then`.

**Why.** A notification with no waiter is lost, so the state must be checked under the same lock as
the park; the parked-first order is exactly the race that a naive protocol hangs on. Shutdown is the
other half of the same protocol: a drain that reports a zero count while completing nothing, or
completes one item twice, has lost or duplicated work the caller staged.

______________________________________________________________________

### SC3 — implementation operation records match the pure model pairwise

**Actor.** An executable client checking LeanIn's refinement.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC3`, which invokes the existing
`controls` executable and the oracle.

**Given.** The same fixed scripted operations, input positions and task identities on both sides.

**When.** The client compares the implementation's records from the executable to the independently
computed `Pool`/`Sched` records.

**Then.** The oracle's records are nonempty first, as the comparison's affirmative control. Then for
every record the parsed `op`, `pos`, `task` and `out` fields match pairwise, and each record is
exactly those four nonempty fields, so an extra, omitted, reordered, duplicated, malformed or wrong
record fails rather than being matched by token presence. The failure names the first record that
differs.

The comparison and its controls are one instrument: a single parsed-record comparator that reads
`op`, `pos`, `task` and `out` each from its own record's named field at the same input index and
requires the four to agree. In the same invocation that comparison runs, that one comparator is also
held to its own controls — it positively accepts the oracle's genuine record against itself, and it
rejects two near misses built only from the oracle's own values: that record with its `task` and
`out` values exchanged between those named fields, and that record with its `pos` value replaced by
the oracle's next position while every other field stays plausible. The near misses exercise the
detector alone; they are never implementation records and never stand in for the implementation
whose absence the `Then` reports. A control that does not hold — a comparator that accepted a near
miss, or that rejected a record against itself — is a fixture defect reported separately from the
`Then`, because a `Then` asserted through an instrument that is not comparing named fields would
otherwise pass or fail for the wrong reason. The empty implementation side still fails the `Then`
itself: the model's records against the implementation's none.

**Why.** The refinement claim rests on the executor's transactions agreeing with the model, so a
model-versus-implementation trace mismatch has to be a failing comparison with the differing record
named, not a difference described in prose.

______________________________________________________________________

### SC4 — a staged scripted failure replays identically, and an alternate script differs

**Actor.** An executable client replaying a scripted run.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC4`, which invokes `controls` twice with
the same seed and scripted inject input and once with an alternate script.

**Given.** Explicit ordered injection inputs, a seed and a script name. The main script carries a
deliberate failing task: task identity `1` fails at input position `3` with the outcome
`error:seeded-failure`. The alternate script delivers identity `2` at that position instead of `1`.

**When.** The client replays the exact seed and scripted input.

**Then.** Each of the three invocations produces exactly one `exec|replay|` record, whose `seed` field
equals the seed given on that command line, and each trace body is a nonempty run of canonical
records — so a missing trace, a retyped seed or a junk body is rejected before anything is compared.
The raw canonical byte traces of the two same-seed invocations of the main script are identical, and
the alternate script's trace differs, so the comparison is not blind. A mismatch reports the first
differing record and the replay inputs.

The failure itself is bound, not merely present. Each of the two main traces must contain exactly one
record with `op=fail`, and that record's own `pos`, `task` and `out` fields must be the staged
`3`, `1` and `error:seeded-failure` — a trace that carries those tokens somewhere else, or a second
failure record, fails. The alternate trace must carry identity `2` in the record at position `3`,
which is the difference the alternate script injects, so the two scripts are distinguished by their
staged identities as well as by their bytes.

The trace checker is exercised inside the same invocation that replays. On a well-formed two-record
canonical trace it must accept the trace and parse it as exactly two records of four fields each,
and it must reject the five near misses of its separator rule: an empty trace, a leading `;`, a
trailing `;`, a doubled `;;` and a lone `;`. The per-record lookup the failure binding reads through
is exercised there too: it finds the single record carrying a named field value, and rejects a value
that no record carries or that two records carry. Those controls are fixture integrity, not the
replay evidence — they show the comparison is made through a checker that can tell a canonical trace
from a malformed one, and that binds a record by its own field — and they neither replace the replay
execution nor satisfy the `Then` above. A control that does not hold is reported separately from the
`Then`, as a defect of the fixture.

**Why.** Deterministic replay is the executor's debugging contract: a failure seen once has to be
reproducible from its inputs, which is only meaningful if the replay reproduces that failure at its
own position and identity, and if a genuinely different script is observed to produce a different
trace.

______________________________________________________________________

### SC15 — the task-local context is inherited, and the registry drains

**Actor.** A Lean executable client of the task layer (`lake exe controls --runtime-registry`), driving
`LeanIn/Task/Basic.lean`'s context operations (`Async.local`, `Async.withLocal`) and
`LeanIn/Task/Registry.lean` (`new`, `spawn`, `size`, `drain`) from computations on one
`Sched.Executor.new LeanIn.Task.Item 256 1`, with `Runtime.Hooks.new` for the gate completions. Nothing
here calls a private function: every compared value is a named field of a record the executable prints
on stdout. The `Local` value a client task installs is `{ requestId := 7, deadline := none, trace :=
"sc15" }`; the default is `{}`.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC15`, which invokes
`lake exe controls --runtime-registry` three times and asserts on the one `context|` record, the one
`registry|` record and the one `registryctl|` checker record each invocation prints. Every compared
value is a named field of its own record, read by key; an absent, repeated or empty field fails the
check rather than resolving to a neighbouring value. An invocation that does not run, prints no record,
prints a malformed record, exits non-zero without the check's `fail` line, or is bounded by the
watchdog is a setup error, never the `Then`.

**Given.** A fresh single-carrier executor `Sched.Executor.new LeanIn.Task.Item 256 1`,
`Runtime.Hooks.new`, and the carrier `IO.getTID` read by the mode's own thread. **Context clause.** Two
`IO.Promise` gates the mode's own steps resolve, so the order is enforced by awaits rather than by a
clock or a socket. Three computations are spawned from the root the mode drives with `Runtime.run`:
`B`, spawned by the root *outside* any `withLocal`; `A`, spawned as `Async.withLocal L7 aBody`, the
client task on which the value is installed; and `A1`, spawned by `A` inside that scope. **Registry
clause.** `k = 4` handlers, `release` and `allParked` as `IO.Promise` gates, and a `Std.Mutex`-guarded
log `{begins, ends, live, liveHigh, handled}`: `handler id` appends `id` to `begins`, resolves
`allParked` when the begin count reaches `k`, awaits `release`, and appends `id` to `ends`. The four
handles are `Registry.spawn reg (handler id)`; the mode keeps the cancelled one's handle. `D` is a
drainer: it resolves `drainStarted`, calls `Registry.drain`, and snapshots the log in the step in which
`drain` returned.

**When.** One invocation, on one carrier, with the order enforced by awaits:

1. The root reads `Async.local` (0) and spawns `B` and `A`.
2. `A` reads `scope ← Async.local` (7), creates the two gates, spawns `A1`, and awaits `A1`'s signal.
3. `A1`'s first step resolves the signal and parks on its gate.
4. `A`'s continuation, woken by the signal, resolves `A1`'s gate and awaits `A1`'s handle.
5. `A1`'s resumed step reads its own `Async.local` and its `IO.getTID`, and returns both.
6. The root awaits the handles and reads `B`'s report (0).
7. The root spawns the four handlers into `reg` and awaits `allParked`.
8. `heldBefore ← Registry.size reg` (4).
9. `Runtime.cancel hooks h3 (.error (.userError "sc15"))`, and the cancelling step appends the cancelled
   id to `ends` — the lifetime ends where the cancellation is issued, SC14's `endConn` shape.
10. The root spawns `D`; `D` resolves `drainStarted`, drains, and snapshots.
11. The root's continuation, woken by `drainStarted`, resolves `release`.
12. Handlers 0, 1, 2 resume and end; `D`'s awaits return; `D` reports its snapshot and returns.
13. The root awaits the taken handle and records `cancelOutcome`, then reads the log a final time and
    prints.

**Then.** There is exactly one `context|` record and one `registry|` record per invocation, shaped
exactly, in this order with nonempty values, as `context|root|scope|child|unrelated|childAfterPark|
carrierCount|carrier|childTid|childOnCarrier|trace|runUs` and `registry|k|heldBefore|begins|
liveHighWater|cancelled|completions|completedAtDrainReturn|liveAtDrainReturn|heldAfter|drainReturned|
cancelOutcome|cancelledEndByHandler|carrier|runUs`. The three clauses are read from their own named
fields:

- **SC15-O1** — the value installed on the client task is read by the computation it spawned, and not
  by a computation it did not spawn: `child == scope`, `unrelated == root`. The affirmative control, in
  the same record, is `scope != root`, so the pair is not a comparison of two defaults; and
  `childOnCarrier == yes` with `childTid == carrier` and `childAfterPark == yes`, so the read happened
  on the carrier, in the child's resumed step. `carrierCount` (recorded `1`, naming why the clause's
  second half is W8's), `trace` and `runUs` are recorded, never asserted.
- **SC15-O2** — `Registry.drain` returns only after the outstanding handlers finish, and the live count
  falls to zero: `heldBefore == k` and `begins == k` (the registry held `k` handles and all began),
  `completions + cancelled == heldBefore` (every held handler is accounted for),
  `completedAtDrainReturn == completions`, `liveAtDrainReturn == 0` and `heldAfter == 0`. The
  affirmative control, in the same record, is `liveHighWater == heldBefore` and `heldBefore != 0`.
- **SC15-O3** — a cancelled handle neither hangs the drain nor runs on: `cancelOutcome == error` (a
  caller awaiting a handle the drain took gets the cancellation), `cancelledEndByHandler == no` (no
  step of the cancelled handler ran after the cancellation; the canceller's own `end` is the control
  that the append is reachable), `heldAfter == 0`, and `drainReturned == yes`.

`cancelled` is the number of handles the mode cancelled; `completions` is the final reading of the
handlers that reached their own end; `completedAtDrainReturn` and `liveAtDrainReturn` are `D`'s
snapshot, taken in the step in which `drain` returned.

**The detectors' own control, in the same run.** `context_ok` and `registry_ok` are the record-string
detectors the assertion is built from. They must accept a well-formed pair written from the record
syntax and the expectation, and reject each near miss: no inheritance (`child == root`), the value
leaked to a non-descendant (`unrelated == scope`), the drain returned early (`completedAtDrainReturn <
completions`, which in the natural red also raises `liveAtDrainReturn`), handles left behind
(`heldAfter != 0`), and a cancelled handler that ran on (`cancelledEndByHandler == yes`). The
delivered near-miss count is five — the sixth variant the record's prose names
(`liveAtDrainReturn != 0`) moves together with `drainEarly` in the natural red, so it is the same
rejection — and a near miss the detector accepts is a fixture defect reported as a setup error,
separately from the `Then`. The mode's own `registryctl|` readings must hold too: `accepted` for the
well-formed pair and `rejected` for each near miss.

**The failure this scenario records on the staged tree.** The staged runtime half is the natural first
cut: `Async.spawn`'s child `Ctx` is built with `local := {}` rather than `ctx.local`, and `Registry.drain`
takes the handle list and clears the registry without awaiting it. Both clauses red deterministically on
one carrier, because the wrong `drain` snapshots the log inside the step that took the list, before the
root's continuation can release the handlers. The check reports the first failing clause — SC15-O1 — as
its own `Then`:

```
SC15 Then: a task spawned from the client does not read the installed local
  observed: scope=7 child=0 root=0 unrelated=0
```

and the same record carries SC15-O2's red: `heldBefore=4 begins=4 cancelled=1 completions=3
completedAtDrainReturn=0 liveAtDrainReturn=3 heldAfter=0`, so `completedAtDrainReturn == completions` is
false against `completions=3`. **SC15-O3 is green on the staged tree**: the cancellation resolves the
cancelled handle's cell (`Join.resolveFirst`), so `drain`'s await takes `Async.await`'s "already there"
path, `cancelOutcome=error`, `cancelledEndByHandler=no`, `heldAfter=0` and `drainReturned=yes`. Its value
is the field that would otherwise be a hang: on the naive directions — awaiting a cell never resolved —
the drain does not return, which the watchdog reports as a defect of the invocation rather than as an
assertion. The record exercises O3's detector by a mutation of the fix (a "cancel-aware" `drain` that
skips handles whose token is set), not by the staged tree. A red is only a red if it is a clause's own
assertion: a missing or malformed record, a non-zero exit without a `fail` line, or a watchdog expiry is
a setup error, not the `Then`.

**Why, and what it rests on.** The value travels where the `ctx` travels, so a child inherits the
innermost enclosing `withLocal` at its spawn site purely by the `ctx` its steps close over — the
reader's signature gains no parameter. The second half of the acceptance clause, "not from a task on
another carrier", is **not observable and is not asserted**: the runtime is single-carrier and the
cross-carrier half is W8's, so `carrierCount=1` records the deferral and the clause is rendered as the
inheritance/non-inheritance pair on one carrier. For the drain, the registry's membership is one
`Std.Mutex`-guarded list; `drain`'s take-and-clear is a single critical section and its awaits happen
outside it, so no `Async` is ever called under the lock. A cancelled handle cannot hang the drain because
`Task.cancel` resolves its cell through `Join.resolveFirst`, and it cannot run on because every step of a
cancelled computation is skipped at `Item.fire`; the presence of the canceller's `end` is what shows the
append is reachable. No assertion is a duration and no order is a clock: the only orderings are enforced
by the `IO.Promise` gates the mode's own steps resolve, and the three invocations must read the same
fields. The mode also prints three measurement rows — `registrybench|`, `registryhand|` and
`registryheld|`, the add path, the drain path and a bare-`List` hand comparison — printed and never
asserted. `runUs` on both records, and `carrier`, are printed, never asserted.

______________________________________________________________________

### SC16 — selection, racing and priority

**Actor.** A Lean executable client of the task layer and the runtime (`lake exe controls
--runtime-select`), driving on one `Sched.Executor.new LeanIn.Task.Item 256 1` per clause with
`Runtime.Hooks.new` for the gate completions: the task-layer `select` and `join`
(`LeanIn/Task/Basic.lean`), the runtime `race` (`LeanIn/Runtime/Leaf.lean`), and `Runtime.spawn` with
its priority argument (`LeanIn/Runtime/Basic.lean`). Nothing here calls a private function: every
compared value is a named field of a record the executable prints on stdout. The carrier is the
mode's own `IO.getTID`.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC16`, which invokes
`lake exe controls --runtime-select` three times and asserts on the one `select|`, one `race|` and one
`priority|` record, and the one `selectctl|` checker record, each invocation prints. Every compared
value is a named field of its own record, read by key; an absent, repeated or empty field fails the
check rather than resolving to a neighbouring value. An invocation that does not run, prints no
record, prints a malformed record, exits non-zero without the check's `fail` line, or is bounded by the
watchdog is a setup error, never the `Then`.

**Given.** Gates are `IO.Promise`s resolved by the mode's own steps, so order is enforced by awaits
rather than by a clock or a socket; `Runtime.Hooks.new` carries the gate registrations, so
`Runtime.pending` is a real reading of outstanding registrations. The readiness log is one
`Std.Mutex`-guarded `List String`: each task's completing step appends its label, so the log records
the order the handles became ready. The served-order log is a second `Std.Mutex`-guarded list: each
spawned task's first step appends its label, so the log is the order the carrier served them.

**When.** Three clauses, each on its own carrier, with the order enforced by awaits:

1. **Selection.** The root spawns `h0`, `h1` and `R` (task-layer `Async.spawn`; their first steps are
   enqueued but none has run, so neither cell is resolved), then in the same step calls
   `select h0 [h1]` and yields. `R` resolves `g1`; `h1` runs, appends `h1` first, resolves `g0`, and
   returns `20`; `h0` appends `h0` second and returns `10`. `select`'s continuation runs and yields
   `(winner, value)`; the root awaits the loser and records `loserValue`, then runs `join [h0, h1]`
   and records `joined`.
2. **Race.** A fresh carrier: spawn `l` and `w`; `l` resolves `lParked`, appends `l-started`, parks on
   `g`, and appends `l-ran` when resumed. The root awaits `lParked`, records
   `pendingBefore ← Runtime.pending hooks`, calls `race hooks (.error (.userError "sc16")) w [l]`,
   records `pendingAfter ← Runtime.pending hooks` **before `g` is released**, then resolves `g` and
   records `loserRanOn` from the log, `loserOutcome` from awaiting `l`, and `loserFinal` from `l`'s
   cell.
3. **Priority.** Two fresh carriers. Preload `k = 4` parked `.normal` tasks; then issue a `.normal`
   and a `.high` fresh spawn in `.normal`-then-`.high` order (recording `normalThenHigh` and
   `servedBeforeHigh`), and repeat with the issue order reversed (recording `highThenNormal` and
   `servedBeforeNormal`).

**Then.** There is exactly one `select|`, one `race|` and one `priority|` record per invocation,
shaped exactly with nonempty values, as `select|left|right|winner|readyOrder|winnerValue|loserValue|
joined|carrier|runUs`, `race|winner|loser|loserOutcome|loserRanOn|pendingBefore|pendingAfter|
winnerRan|loserFinal|runUs`, and `priority|k|normalThenHigh|highThenNormal|servedBeforeHigh|
servedBeforeNormal|runUs`. The three clauses are read from their own named fields:

- **SC16-O1** — the handle that became ready first is the one `select` returned: `winner ==
  readyOrder[0]`, both operands bound to their own field. The affirmative control, in the same record,
  is that `readyOrder` has exactly two entries with `left != right`, and that `winner == h1` while
  `readyOrder == h1,h0` — so the relation is not `x == x`; and `select` left the loser running
  (`loserValue == 10`, its own value produced after `select` returned), with `join` collecting both
  values in list order (`joined == 10,20`). `winnerValue`, `carrier` and `runUs` are recorded, never
  asserted.
- **SC16-O2** — `race` cancels its losers with W5's laws: `loserOutcome == error` (a caller awaiting
  the cancelled loser gets the race's value, exactly once), `loserRanOn == no` (no step of the loser
  ran after the race returned), `loserFinal == error`, and `pendingAfter == 0` read immediately after
  `race` returned and before the loser's gate is released. The control, in the same record, is
  `winnerRan == yes` and `pendingBefore != 0`: the loser was parked with a registration before the
  race, so `pendingAfter == 0` is a change of state, not a reading of zero.
- **SC16-O3** — the priority argument changes the order the queue serves: `normalThenHigh ==
  high,normal` and `highThenNormal == high,normal` (a `.high` spawn is served before a `.normal` spawn
  regardless of issue order), with `servedBeforeHigh == 0` and `servedBeforeNormal == k`. The control,
  in the same record, is `k != 0`, so `servedBeforeNormal == k` is not two zero counts; and
  `highThenNormal` is the issue-order-reversed repeat that would pass even were the argument ignored,
  so it is the affirmative control for the log's readability rather than the assertion.

**The detectors' own control, in the same run.** `select_ok`, `race_ok` and `priority_ok` are the
record-string detectors the assertions are built from. They must accept a well-formed trio written
from the record syntax and the expectation, and reject each near miss, one per clause: a list-ordered
`select` whose head won (`winner=h0` while `readyOrder=h1,h0`), a race that left its loser running
(`loserRanOn=yes`), a race that did not retire the loser's registration (`pendingAfter=1`), and a
placement that ignored the priority argument (`normalThenHigh=normal,high`). The delivered near-miss
count is four, and a near miss the detector accepts is a fixture defect reported as a setup error,
separately from the `Then`. The mode's own `selectctl|` readings must hold too: `accepted` for the
well-formed trio, `rejected` for each near miss, and `variants` naming the four near-miss variants
tested.

**The failure this scenario records on the staged tree.** The operations are new, so the staged first
cuts are the plausible ones: `select` staged as a list-ordered await of the head (it never registers
on a later handle, so a handle that became ready first is invisible to it), `race` staged as `select`
with no cancellation, and `spawn` staged as ignoring its priority argument (both lanes take the ring,
so a `.high` spawn issued after a `.normal` spawn lands behind it). The check reports the first failing
clause — SC16-O1 — as its own `Then`:

```
SC16 Then: the handle that became ready second won
  observed: winner=h0 readyOrder=h1,h0
```

and the same run's `race|` record carries `loserOutcome=ok loserRanOn=yes pendingAfter=1`, while its
`priority|` record carries `normalThenHigh=normal,high`. On the fixed tree the three read
`winner=h1 readyOrder=h1,h0`, `loserOutcome=error loserRanOn=no pendingAfter=0`, and
`normalThenHigh=high,normal`. A red is only a red if it is a clause's own assertion: a missing or
malformed record, a non-zero exit without a `fail` line, or a watchdog expiry is a setup error, not
the `Then`. `select` must be called in the spawn step, before any handle resolves — called later, an
already-resolved handle wins by list order and O1's red vanishes; and `h1` resolves `g0` in its own
body, so both handles resolve and the staged `select` does not hang.

**Why, and what it rests on.** First-ready-wins is the `Join.resolveFirst` law (`Basic.lean`): a
handle resolved while `select` waits resolves the shared target and a later resolution is ignored,
which is why the root calls `select` before any child has run. `select` does not cancel its losers
because the task layer has no `Hooks` to retire a registration and "wait for the first of several,
then continue with the rest" is a legitimate use; `race` adds `cancel`, so a loser resolves with the
race's value exactly once and immediately (`resolveFirst`), no step of it runs afterwards
(`Item.fire`), and its registration is retired (`hooks.retire`). The priority argument is a placement
choice — `.high` uses the one-slot LIFO buffer, `.normal` the FIFO ring — and promises nothing about
when a task runs. No assertion is a duration and no order is a clock: the only orderings are the gates
the mode's own steps resolve, and `carrier` and `runUs` are printed, never asserted. The mode also
prints four measurement rows — `selectbench|`, `racebench|`, `priorityorder|` and `prioritybench|` —
printed and never asserted.

______________________________________________________________________

### SC17 — a handle spawns onto a running executor, a signal stops then drains, and a timeout is read from a harness clock

**Actor.** The public `controls` executable (`lake exe controls --runtime-handle --ready-file PATH`),
driven in the background by the fixture, playing three actors: for clause one, the mode's own thread — a
thread that is **not** a carrier — plus one dedicated `IO.asTask (Runtime.run e1 program) …` thread that
is; for clause two, the executable's accept loop on a carrier plus the shell fixture, which is the
process that delivers the signal; for clause three, the calling thread driving a virtual clock. Nothing
here calls a private function: every compared value is a named field of a record the executable printed
on stdout.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC17`, which starts the executable in the
background, polls the marker file it publishes with a bound, sends `SIGTERM` to the pid the marker
names (tolerating a pid that has already exited — the signal's delivery is asserted by the scenario, not
by the fixture), waits for it to exit, and parses the records it printed. The one externally delivered
event in the scenario is that signal. An invocation that does not run, prints no record, prints a
malformed record, publishes no marker, exits non-zero without the check's `fail` line, or is bounded by
the watchdog is a setup error, never the `Then`.

**Given.** A fresh single-carrier `Sched.Executor.new LeanIn.Task.Item 256 1` and `Runtime.Hooks.new`
per clause. **Clause one.** A `Runtime.Handle` over `e1`; the run's program parks on a task-layer
`Join` cell, and the cell is resolved by the spawned computation the mode sends through the handle.
**Clause two.** A `Runtime.Listener.bind 127.0.0.1:0`, a `Std.Mutex`-guarded accept counter, a
`Std.Mutex`-guarded event log, an `IO.Promise` gate the served body parks on, an `IO.Promise` for "the
stop was observed", and a 9-byte payload; the run's program publishes the listener address, spawns
`Runtime.serveUntilStopped hooks e2 l 1 body []`, registers a `.sigterm` waiter and awaits it through
`Runtime.awaitSignal`. **Clause three.** A fresh `HarnessClock` per arm, `Clock := HarnessClock.clock
hc`, and the stated instants `completesAt = 30`, `longDeadline = 100`, `shortDeadline = 20`.

**When.** One invocation, three clauses, with every ordering enforced by the mode's own awaits and never
by which thread wins:

1. **The handle.** The mode starts the run on a dedicated thread and, from its own thread, waits until
   `Handle.metrics` reports `ready = 0, parked = 1` (the carrier is parked inside the driver's wait).
   It then calls `Handle.spawn h1 .normal spawned` once; `spawned` records `IO.getTID` and resolves the
   program's cell.
2. **The signal.** The main thread connects the first client and sends the payload, then waits (bounded
   by "the accept counter read 1, or the carrier task finished") and writes the marker file with its own
   pid. The fixture sees the marker and sends `SIGTERM`. The handler step — resumed on the carrier from
   the registered waiter — records `signal` and `stop-observed`, calls `Handle.stop`, and resolves the
   gate; the loop stops accepting and drains the one handle it holds; the body echoes and finishes; the
   drain returns. After observing the stop, the main thread connects a second client, sends the payload
   and closes it without reading, counting `offered = 2`.
3. **The clock.** Three arms, each its own `Runtime.runVirtual hc e3` on the calling thread: the longer
   deadline does not trip (`withTimeout c 100 (sleep c 30; pure 7)`), the shorter deadline is the same
   test at `20`, and a deadline raced against a timer handle is `Task.select` over a spawned
   `sleep c 30` and a spawned await of a gate that is never resolved.

**Then.** There is exactly one `handle|`, one `clock|`, one `signal|` and one `tokens|` record per
invocation, shaped exactly with nonempty values, as `handle|spawnTid|ranTid|carrierTid|readyBefore|
parkedBefore|readyAfter|parkedAfter|runUs`, `clock|completesAt|longDeadline|longOutcome|longElapsed|
shortDeadline|shortOutcome|shortElapsed|pendingAfter|deadlineAt|deadlineWinner|runUs`,
`signal|signal|signalSeen|stopSeen|handlerCarrier|acceptedAtStop|acceptedFinal|offered|bodyDone|
inFlightAfter|pendingHooks|listener|log|runUs`, and `tokens|sequential|sequentialDistinct|contended|
contendedDistinct`. The clauses are read from their own named fields:

- **SC17-O1 — a non-carrier thread spawns and the work runs on a carrier.** `ranTid == carrierTid` and
  `ranTid != spawnTid` with `carrierTid != spawnTid`, so the work ran on a carrier and not on the thread
  that spawned it. The affirmative control, in the same record, is `parkedBefore == 1` and
  `readyBefore == 0`: the carrier was parked when the foreign spawn arrived, so the wake protocol was
  exercised rather than a spawn into an idle pool; and `readyAfter == 0`, `parkedAfter == 0`, so the run
  returned with nothing held and nobody parked.
- **SC17-O2 — a registered signal stops accepting, then drains.** `signal == 15` (SIGTERM on this
  platform) and `signalSeen == yes`; the stop was observed before the second offer and no later
  connection was accepted (`acceptedFinal == 1` while `offered == 2`, and no `accept:2` in the log). The
  affirmative control, in the same run, is `acceptedAtStop == 1` — the counter did move for the
  connection offered before the stop, so `acceptedFinal == 1` is a reading about a loop that can count,
  not a counter stuck at zero, and `offered == 2` makes it non-vacuous. The connection in flight
  completed (`bodyDone == yes`, `drain-returned` after `body-echoed`); the drain returned with nothing held
  and nothing outstanding (`inFlightAfter == 0`, `pendingHooks == 0`); the handler's step ran on a
  carrier (`handlerCarrier == yes`); and the socket outlived its last use (`listener` nonempty, read
  after the drain). The log relation is exactly one `accept:1`, one `offer:2`, one `stop-observed`, one
  `body-echoed`, one `drain-returned`, with `accept:1 < stop-observed < body-echoed < drain-returned`
  and `stop-observed < offer:2`.
- **SC17-O3 — a timeout whose elapsed time is read from the harness clock.** `longOutcome == some:7` and
  `longElapsed == completesAt`; `shortDeadline < completesAt` (the control is proved shorter, so the
  pair is a relation and not two numbers), `shortOutcome == none` and `shortElapsed == shortDeadline`;
  `pendingAfter == 1` (the run ended at the winning instant without advancing to the loser); and
  `deadlineWinner == timer` with `deadlineAt == completesAt`. `runUs` on every record, `carrierTid`, the
  counters' per-carrier `carriers` field and the three measurement rows are printed and never asserted.

**The detectors' own control, in the same run.** `handle_ok`, `signal_ok`, `clock_ok` and `tokens_ok`
are the record-string detectors the assertions are built from, and `signal_log_ok` is the log relation
inside `signal_ok`. They must accept a well-formed record written from the record syntax and the
expectation, and reject each near miss, one per clause plus this one: the work ran on the calling thread
(`ranTid = spawnTid`), a connection offered after the stop was accepted (`acceptedFinal = 2`), the
harness clock never advanced (`longElapsed = 0`), and a duplicate token id was handed out
(`sequentialDistinct = sequential - 1`). The delivered near-miss count is four — the fourth is the
token-id control's — and a near miss the detector accepts is a fixture defect reported as a setup error,
separately from the `Then`. The mode's own `handlectl|` readings must hold too: `accepted` for the
well-formed set, `rejected` for each of the four near misses, and `variants = 4`.

**Assertion order.** `check_sc17` evaluates the three clauses first, in order O1, O2, O3, and the
`tokens|` control after them, so the first assertion a run reports is never the one whose failure is
interleaving-dependent.

**The failure this scenario records on the staged tree.** The operations are new, and the staging is a
plausible first cut per clause. `Handle.spawn` fires the item on the calling thread instead of routing
through `Executor.spawnBase`/`submitBase`, so `ranTid = spawnTid`; `Runtime.awaitSignal` creates the
waiter and calls `wait` — the watcher is registered — but returns at once rather than awaiting the
returned task, so the handler stops the executor before the first connection is offered and the accept
counter never moves; and `HarnessClock.clock`'s `sleep` schedules at `now` rather than `now + d`, so
every timer fires at instant zero. The check reports the first failing clause — SC17-O1 — as its own
`Then`:

```
SC17 Then: the spawned work did not run on a carrier
  observed: spawnTid=<main> ranTid=<main> carrierTid=<carrier> parkedBefore=1
```

The same run's `clock|` record carries `longElapsed=0 completesAt=30 longOutcome=some:7` (and
`shortOutcome=none`, `shortElapsed=0`), and its `signal|` record carries `acceptedAtStop=0
acceptedFinal=0 offered=2 signalSeen=no stopSeen=yes bodyDone=no log=[stop-observed,drain-returned,
offer:2]`. On the fixed tree the three read `ranTid=carrierTid ≠ spawnTid`, `longElapsed=30` with
`shortOutcome=none`, and `signal=15 signalSeen=yes acceptedAtStop=1 acceptedFinal=1 bodyDone=yes`. The
`tokens|` control's sequential half stayed `sequential=64 sequentialDistinct=64` on every staged run —
deterministic, and it holds. Its contended half read `contended=128 contendedDistinct=126` on the staged
tree in the run that caught it: two duplicate token ids handed out by the unfixed allocator under two
foreign threads. That run is the defect the control exists for; other runs read `contendedDistinct=128`
because the interleaving has to go unluckily, and the reading holds on every run once the allocator's
read-modify-write is inside a critical section. The contended half can therefore pass on the unfixed
tree, which is why it is a control and the fourth `handlectl|` variant rather than a clause or a gate's
red. A red is only a red if it is a clause's own assertion: a missing or malformed record, a signal that
killed the process, a marker that never appeared, or a watchdog expiry is a setup error, not the `Then`.

**Why, and what it rests on.** Clause one is the reason the handle exists: a thread that is not a carrier
originates work, the wake is delivered by `submitBase`'s check-and-notify under the same lock the
parking predicate is re-checked under, and the counters are read through the model projection across the
thread boundary. The handle is not a `Send` marker and the claim is argued, not proved — the
serializability lemma `docs/primitive-theory.md` §4 states as unproved is what would close it — so the
scenario asserts tids and counters, not sharing. Clause two's signal is real and delivered from outside:
the waiter is a libuv watcher whose handler resolves the promise on the loop thread, and the awaiting
continuation reaches our executor only through W1's seam, so the delivery thread only enqueues and the
handler's step runs on a carrier, which the record reads as `handlerCarrier`. Every ordering is enforced
by the mode's awaits — the marker and the counter for `accept:1 < stop-observed`, the gate for
`stop-observed < body-echoed`, the loop's own `Registry.drain` for `body-echoed < drain-returned`, and
the stop promise for `stop-observed < offer:2` — never by which thread wins; and the second connection
cannot be accepted because the accept is non-blocking and the loop checks `isStopping` before every
accept attempt, so a connection created after the stop meets a check, not a `tryAccept`. Clause three
states the clock claim in its strongest clock-free form: the elapsed time is read from `HarnessClock`'s
virtual instant and compared against the instants the mode stated, so no scenario reads a live clock.

______________________________________________________________________

### SC18 — the carriers, the thief, and a wake from a thread that is not a carrier

**Actor.** The public `controls` executable in a new mode, `lake exe controls --runtime-carriers
[--workers P] [--bound N]` (defaults `P = 4`, `N = 20000`), playing three actors over one run: for
clause one, the multi-carrier entry `Runtime.runCarriers e p program`, whose fixed shape starts `P`
dedicated `IO.asTask (Executor.workerLoop e i) Task.Priority.dedicated` threads through
`Runtime.startCarriers` while the mode's own thread **is not** a carrier and only waits; for clause two,
the mode's thread driving one steal through the public `Executor.stealInto` against a worker it staged
itself; for clause three, the mode's thread pushing through `Handle.spawn` while all `P` carriers are
parked. Nothing here calls a private function: every compared value is a named field of a record the
executable printed on stdout.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC18`, which invokes the executable
synchronously and parses its records. The invocation's watchdog is raised for this check to a stated
value (1200 s), because the scale arm's cost is the shared cell's contention and not a throughput figure
a 300 s bound covers; a bound the requirement itself exceeds is a setup error waiting to happen. An
invocation that does not run, prints no record, prints a malformed record, exits non-zero without the
check's printed clause lines, or is bounded by the watchdog is a **setup error**, never the `Then`.

**Given.** A fresh `Sched.Executor.new LeanIn.Task.Item 256 P` (`P = 4` for the parallel arm, `1` for the
single-carrier control arm), metered so the per-carrier counters are readable. A `Std.Mutex`-guarded
`List UInt64` of the tids the started carriers recorded, and the mode's own completion cells. Clause
two's staging: a `Runtime.run e (spawnburst 200)` prelude leaves worker `0`'s ring holding 200 and its
slot empty, a clean worker as the empty victim, and a `spawnInto` that puts one item in a third worker's
**slot** with an empty ring. Clause three's stage: all `P` carriers started and observed parked, and one
task-layer `Join` cell the pushed computation resolves.

**When.** One invocation, three clauses, every ordering enforced by the mode's own steps and never by
which carrier wins:

1. **The parallel arm.** The mode calls **`Runtime.runCarriers e p program`** — the multi-carrier entry,
   which starts the `p` carriers and submits the program's root to the shared inject — and waits for the
   program's completion; the mode's own thread is **not** a carrier and cannot `Async.await`, so the wait
   is the entry's, and the mode's own completion reads are the bounded round polls below. **This is the
   one shape**: the drafted `Runtime.run e root` followed by `Runtime.startCarriers e workers` is
   superseded, because `run` keeps worker 0 on the calling thread by design (§3.3), so every body fires on
   the caller and `startCarriers` runs against an already-drained inject — `distinctCarriers` then reads
   the same on the staged tree and on the fixed one, which makes the cut inert and the clause unable to
   yield its fixed reading. Under the entry shape the staged cut (the entry starts **no** carriers and
   drives the program on the caller, so `carriers = 0`, `carrierTids = []` and `ranTids = [<main>]`) is read
   by the clause's `ranTids ⊆ carrierTids` binding, and the fixed entry is read by the same binding holding
   with `carriers = p`. The **control arm** is the same program at `P = 1`, read by the same detector.
2. **The steal.** The mode calls the public steal from worker `1` against worker `0` once, recording the
   victim's ring before and after and its slot either side, and the thief's own ring and slot after. Then
   the same call against the empty worker, and the same call against the worker whose **slot** holds one
   and whose ring is empty — that victim's slot is read **before and after** the third call, and
   `slotStolen` is computed from the two occupancy readings (`no` exactly when the slot was occupied and
   is still occupied after), so an empty slot cannot produce a `no`.
3. **The wake.** With the `P` carriers started and observed parked (`Handle.metrics`' `parked = P`,
   `ready = 0`, polled in the bounded round loop), the mode pushes one computation through
   `Handle.spawn`; it waits on that cell by the same bounded poll; then pushes a second; then reads
   `parked`/`ready` again, then `stop`s and `join`s, and reads `Executor.observe` and `Runtime.pending`
   after the drain. The **scale arm** is one more `P = 4` run with `n = 100000` tasks, reading only
   `remaining`.

Every wait the mode makes itself is a **round count** bounded by `--bound`, never a clock: an expiry yields
`wokeRounds = bound` and the clause's reading fails; it is not a hang, and the shell's watchdog remains only
a hang bound. (The parallel entry's own wait is the entry's, and the staged cut drives the caller inside it;
the mode's own reads of `Join.value?` are the round-bounded ones, and the wake detector compares `wokeRounds`
against the same `--bound`.) The
run durations (`runUs`) and the measurement rows are printed and never asserted: the `parbatch` sweep at
`p = 1, 2, 4, 8` with the box's core count and a `parbatchcond` line stating the condition to its endpoints
(`ratio(pMax)` against `ratio(1)`, a halving margin, the interior arms reported and not asserted between
their neighbours), a `chain` row per construction measured — the recorded `Async.spawn`/`await` chain
without per-link instrumentation, and the same construction with it — each naming its construction with the
ratio as a multiplier, and the driven-steal `stealbench` pair, which is not like-for-like and says so.
A timing assertion is a flake with a schedule, so every row is a reading and none is a gate.

**Then.** There is exactly one `carriers|` and one `steal|` record per invocation, shaped exactly with
nonempty values, as `carriers|carriers|p|carrierTids|ranTids|distinctCarriers|carrierCount1|chainCarriers|
parkedBefore|readyBefore|ranTid|spawnTid|inWorkerTids|wokeRounds|ran1|ran2|parkedAfter|readyAfter|
inFlightAfter|pendingHooks|scaleN|remaining|runUs` and `steal|victimRingBefore|victimSlotBefore|stolen|
victimRingAfter|victimSlotAfter|stolenFromEmpty|emptyVictimRingBefore|slotStolen|slotVictimSlotBefore|
thiefRingAfter|thiefSlotAfter|thiefTid|victimTid`, plus the mode's `sendctl|marked|unmarkedPushes`,
`carriersctl|accepted|rejected|variants` and `carrierscfg|bound|workers` lines. The clauses are read from
their own named fields:

- **SC18-O1 — P carriers ran the work.** `p = 4`, `distinctCarriers ≥ 2`, and every tid in `ranTids` is
  one of the carriers' own (`ranTids ⊆ carrierTids`, so the work ran on the *started* carriers and not on
  the thread that called the entry). The affirmative control, in the same run, is `carrierCount1 = 1`:
  the same detector on the `P = 1` arm reads exactly one distinct carrier tid, so `≥ 2` at `P = 4` is a
  reading about a detector that can also read one. `chainCarriers` is bound by its own named field — so a
  record whose shape lost it is rejected — and its value is compared in no clause, the same treatment SC19's
  `pendingHooks` received under D20: the route rebinding makes the count a consequence of the scheduler's
  choice — a chain follows the worker that fires each link — so no fixed value is a property of this clause.
  The record's
  `carriers` field — how many carriers the entry actually started, `Carriers.count`, read before the
  carriers are stopped — is shape-checked but deliberately **not** one of O1's bindings: the red is the
  relation `ranTids ⊆ carrierTids`, not this count (under the staged entry `carriers` reads `0` and the
  caller's tid is in `ranTids` while `carrierTids` is empty).
- **SC18-O2 — a thief takes exactly one, from the ring and never from the LIFO slot.** `stolen = 1`,
  `victimRingBefore ≥ 1`, `victimRingAfter + 1 = victimRingBefore`, and `victimSlotAfter =
  victimSlotBefore` with `slotStolen = no`. **The slot half is bound to an occupancy reading, not
  assumed**: the record carries `slotVictimSlotBefore` (the slot-only victim's slot as the call read it)
  and the clause asserts it is `some`, so `slotStolen = no` cannot pass on an empty slot — under a
  ring-only steal an empty slot yields the same `no`, which is exactly the gap this closes — and
  `slotStolen` is computed as "the victim's slot was occupied and is still occupied after", not from the
  call's return. The thief's own side is read too, and it is what makes the batch observable rather than
  inferred: `thiefRingAfter = 0` and `thiefSlotAfter = -`, where a steal that also staged an element in
  the thief's own slot would read `some`. The controls, in the same run: `stolenFromEmpty = 0` with
  `emptyVictimRingBefore = 0` — the same call that reads 1 also reads 0 — and the slot-only victim's
  `slotStolen = no` with `slotVictimSlotBefore = some`, which is the affirmative control that the LIFO
  slot is genuinely out of a thief's reach.
- **SC18-O3 — a push from a thread that is not a carrier wakes a parked carrier, and the drain leaves
  nothing held.** `parkedBefore = p`, `readyBefore = 0` (all parked, nothing ready, so the protocol was
  exercised rather than a push into an idle pool); `ranTid ≠ spawnTid` and `inWorkerTids = yes` (the work
  ran on a carrier, not on the thread that spawned it); `wokeRounds < bound`; `ran1 = yes` and
  `ran2 = yes` (the same protocol woke twice, so one wake is not a single-shot accident); then
  `inFlightAfter = 0` and `pendingHooks = 0`. `wokeRounds < bound` is read against the bound the mode
  printed (`carrierscfg|bound`), not a literal, so a mode run at another bound cannot silently pass; a
  bound that expires is read as `wokeRounds = bound` with this clause's own assertion failing, never as a
  setup error. **And the chain arm starts its carriers too**, which is what keeps a crossing possible rather
  than a construction artifact: with `p` carriers running, a thief can reach a ring item of the carrier
  running the chain, so a link may run on a carrier other than its creator's — the reading W18's route
  rebinding makes legitimate, and which the clause no longer asserts against (`chainCarriers` is compared in
  no clause). The **scale
  arm**'s `remaining = 0` at `scaleN = 100000` is the affirmative control for "a carrier that parks
  mid-run is woken again" at a size that forces many parks and wakes.

**The staged and fixed readings, field by field.** Every clause field is written for **both** trees,
because a fixed-tree reading read as the staged one is how the earlier draft's F2 arose. The assertion is
the clause's on the **fixed** tree; the staged value is recorded beside it, and a field whose staged value
is the clause's own subject is both.

| field | staged | fixed |
|---|---|---|
| `carriers` | `0` — the staged entry starts no carriers | `p` — started equals requested |
| `carrierTids` | `[]` | the `p` dedicated tids |
| `distinctCarriers` (`p = 4`) | `1` — the caller alone | `4`, all from `carrierTids` |
| `ranTids ⊆ carrierTids` | **no** — the caller's tid is in `ranTids` and `carrierTids` is empty | yes |
| `carrierCount1` | `1` | `1` |
| `chainCarriers` | not asserted — bound by its own named field and shape-checked, its value compared in no clause (the same treatment in substance that D20 gave SC19's and SC20's `pendingHooks`, and stricter in form: the field keeps a numeric shape gate where that binding has none); the rebinding makes a crossing legitimate, so no fixed value is a property of this clause | not asserted, for the same reason |
| `parkedBefore` (O3) | `p` | `p` — **no cut here**, so clause three is green on both trees and its red is unavailable |
| O2's fields | as recorded (the batch-two cut: `victimRingAfter + 2 = victimRingBefore`, `thiefSlotAfter = some`) | as recorded (batch one: `victimRingAfter + 1 = victimRingBefore`, `thiefSlotAfter = -`); `slotVictimSlotBefore = some` in both |

So **`chainCarriers` is asserted on neither tree**: the route rebinding makes the count a consequence of the
scheduler's choice — a chain follows the worker that fires each link — so the fixture binds and shape-checks
the field and compares it in no clause, and the field's reading is left to the measurement rows rather than
asserted as a fixed-tree property. The chain arm keeps starting its carriers, because with none started a
crossing could not have been observed and the field's reading would be vacuous.

**The detectors' own control, in the same run.** `carriers_ok`, `steal_ok` and `wake_ok` are the
record-string detectors the assertions are built from. They must accept a well-formed record written from
the record syntax and the expectation, and reject each near miss:
the work ran on the thread that spawned it (`ranTid = spawnTid`), a thief took two from the ring
(`victimRingAfter = victimRingBefore - 2`, the shape this tree's clause-two cut produces), and the
slot-cleared record a slot-taking thief would produce (`slotStolen = yes`). `carriers_ok` is also shown
**accepting** a well-formed record carrying `chainCarriers = 2` — the legitimately-crossed shape W18's route
rebinding makes — so the amendment trades the old rejection for an affirmation rather than dropping a
control: a chain across carriers is the correct reading now, not a near miss. The delivered near-miss count
is three; a near miss a detector accepts is a fixture
defect reported as a **setup error**, separately from the `Then`. The mode's own `carriersctl|` readings
must hold too: `accepted` for the mode's accepted set — `[carriersOk carriersGoodRec, stealOk stealGoodRec,
carriersOk carriersNearChain]`, three records rather than a pair — `rejected` for each near miss the mode's
own self-check exercises, and `variants = 3`; and its `sendctl|unmarkedPushes` must read `0`. The third
record's chain field is read through `carriersOk`'s numeric shape gate before being compared in no clause: the
same treatment in substance that D20 gave SC19's and SC20's `pendingHooks`, and stricter in form, since that
binding keeps no numeric gate. **The authority for those
readings is the shell fixture's own exercises, not the mode's line**: the mode prints `carriersctl|` and
`sendctl|` as fixed strings describing the exercises it checks rather than
readings of the system, and the near-miss rejections are proved by the fixture's own `setup_error` paths,
which build each near miss from the record syntax and the expectation rather than from the executable's
receipt. A printed constant must not be mistaken for evidence.

**Assertion order.** `check_sc18` evaluates the three clauses on their own named fields, in order O1, O2,
O3, and evaluates all three so the ones that hold are observed to hold. On a tree where more than one
fails it prints each failing clause's own assertion, in clause order, before it exits; the first line a
run reports is therefore always SC18-O1's.

**The failure this scenario records on the staged tree.** The multi-carrier operations are new, and the
staged surface carries one plausible first cut per clause. **Clause one's staged entry starts no carriers
and drives the program on the calling thread**, so the caller runs every item and the carriers' detector
counts none of them: `carriers = 0`, `carrierTids = []`, `distinctCarriers = 1` for the caller alone, and
`ranTids = [<main>]` with `ranTids ⊄ carrierTids` — the red is the **relation**, so it does not depend on
which carrier wins. (The earlier `p−1`-carrier form of this cut was a race — the caller ran none of the 2048
bodies in 2 of 23 runs — and a clause's red cannot be a race.) The `P = 1` control still reads
`carrierCount1 = 1`. Clause two's staged steal takes a **batch of two** from the victim's ring
and gives the second to the thief's own slot, so the ring loses two where the design loses one and the
thief's slot reads `some`. **Clause three has no staged red**: the parked-accounting cut is withdrawn
(record §7), so `parkedBefore` reads `p` on the staged tree too and its wake readings pass — the run
completes and the drain empties the queued work. The check prints the failing clauses it finds, in clause
order — the first failing clause is SC18-O1:

```
SC18 Then: the work did not run on more than one carrier
  observed: p=4 carriers=0 carrierCount1=1 distinctCarriers=1 spawnTid=<main> ranTids=[<main>] carrierTids=[]
SC18 Then: a thief took more than one element from the victim's ring
  observed: victimRingBefore=200 victimRingAfter=198 victimSlotBefore=- victimSlotAfter=- slotStolen=no slotVictimSlotBefore=some stolen=1 thiefSlotAfter=some stolenFromEmpty=0
```

and **no O3 `Then` is printed**: clause three is green on the staged tree, so it contributes no line.

The same fields on the fixed tree read `carriers = 4`, `carrierTids` = the four carriers, then
`distinctCarriers = 4` with `ranTids ⊆ carrierTids` and `parkedBefore = 4`, and clause
two reads `victimRingAfter = 199` with `thiefSlotAfter = -`. A red is only a red if it is a clause's own
assertion: a missing or malformed record, a non-zero exit without the check's printed lines, or a watchdog
expiry is a setup error, not the `Then`. Clause three's evidence is SC17-O1 at `P = 1` (a foreign push
against a parked carrier, green on every run since W13), the model's `Model.Multi.reachable_live` with
`ZeroParked` and `InjectWatched`, and this clause's own readings on the fixed tree, the scale arm included —
a green O3 must **not** be read as the wake having been measured by a staged red, because there is none. The
`sendctl|` readings are not reds: the marker's enforcement is a compile-level fact.

**Why, and what it rests on.** Clause one is the deliverable: work is spread over `P` carriers rather
than run on the caller. Clause two is D4's inversion made observable — one element, from the ring, never
the slot, so batching and slot-stealing would both fail it. Clause three is the model obligation a
scenario can observe: a waker on another thread, all carriers parked, the work still runs exactly once,
and the drain leaves nothing behind. Clause one is **not vacuous** only because its control arm reads
one; clause two is not vacuous only because the same operation reads zero on an empty victim and cannot
see the slot; clause three is not vacuous only because `parkedBefore = p` and `readyBefore = 0` make the
push the waking event, and because SC17 already owns the single-carrier version of the same claim. Every
ordering is enforced by the mode's own awaits — the `P = 1` arm, the `Join` cells, and the round-bounded
polls — never by which thread wins, and no assertion reads a clock: the run durations and the four rows
are printed and never asserted, because a timing assertion is a flake with a schedule.

______________________________________________________________________

### SC14 — the service's own obligations: no drop, a live bound, and resolution within a deadline

**Actor.** A Lean executable server (`lake exe controls --runtime-service`): an accept loop of ours
plus a per-connection body, run on one carrier, with `Std.Async`'s client as the peer. The promises a
client sees are the connection's fate and the request's answer, and they are named by
`LeanIn/Model/Service.lean`'s `Service.NoDrop`, `Service.Bounded`, `Service.RequestsResolved` and
`Service.PendingWithinLive`. Nothing here calls a private function: the client speaks TCP to the
server's own bound socket, and the check reads the executable's stdout and its exit status.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC14`, which invokes
`lake exe controls --runtime-service --bound=2` three times and asserts on the one `service|` record
each invocation prints, plus the mode's own `servicectl|` checker readings. Every compared value is a
named field of that record, read by key; an absent, repeated or empty field fails the check rather
than resolving to a neighbouring value.

**Given.** A fresh single-carrier executor (`Sched.Executor.new LeanIn.Task.Item 256 1`), a listener
bound to `127.0.0.1:0` (`Runtime.loopback 0`), a bound `B = 2`, and `n = 5` connections whose payload
is one byte, the connection's id. The client stages connection identities `0..4`; the body's response
is staged per id: id `1`'s response is `Runtime.never` (`LeanIn/Runtime/Time.lean:36`), so its deadline
fires rather than its response; id `3`'s response fails with a staged error, so it terminates without
completing; ids `0`, `2`, `4` echo and complete. The client sends the staged ids `1` and `3` last.

**When.** In one invocation: the loop starts the server, the client connects all five sockets and
sends each id, and — before reading or closing anything — waits on the mode's `Std.Mutex`-guarded
admission log until it holds the begins the loop's admission policy requires: `B` begins on a loop
that admits `B` and waits on a permit, every offered begin on a loop that admits unconditionally. It
then reads each admitted socket's reply in that log's order and closes it; the body that owns a closed
socket ends, so the read order is the server's own begin order and not the OS's connect order or a
scheduler race. The loop drains and returns when every body has ended, and the mode prints the
`service|` record and its `servicectl|` readings.

**Then.** There is exactly one `service|` record, and its fields are exactly, in this order with
nonempty values: `bound`, `offered`, `accepted`, `completed`, `closed`, `liveHighWater`,
`parkedAtPeak`, `requests`, `responded`, `errored`, `deadlineFired`, `carrier`, `runUs`. The three
obligations are read from their own named fields, each in the multiset or inequality the model
statement names:

- **SC14-O1** — `Service.NoDrop`: `completed ∪ closed`, as an id multiset, equals `accepted`. The
  affirmative control, read from the same record, is that `completed` and `closed` are both nonempty, so
  the equality is not carried by one path alone. That union equality and those two nonemptinesses are
  the whole of the assertion: `accepted`'s own value (`[0,1,2,3,4]` here) and `offered` are printed but
  never asserted, and neither terminal list is compared against a named id.
- **SC14-O2** — `Service.Bounded`: `liveHighWater ≤ bound`, and the affirmative control
  `liveHighWater = bound`. `parkedAtPeak` is the mode's second reading of the same count, from its own
  running annotation, and reads `bound` too.
- **SC14-O3** — `Service.RequestsResolved` and `Service.PendingWithinLive`: `responded ∪ errored`, as
  an id multiset, equals `requests` disjointly, so every request id is resolved exactly once and none
  is outstanding. The affirmative controls, in the same record, are `deadlineFired = yes` (id `1`'s
  request was resolved by the deadline transition) and `responded` and `errored` both nonempty.

`runUs` is printed and never asserted; `carrier` and `offered` are recorded, not asserted. The record
is a set of order-independent equalities and one inequality, because the order bodies finish in belongs
to the scheduler: `completed`, `closed`, `responded` and `errored` are compared as multisets, and
`accepted`/`requests` are printed in ascending id order.

**The failure this scenario records on the shipped loop.** The accept loop in the tree as it stands
admits every offered connection — one accepted socket and one spawned body each, with no admission
bound. The mode's body therefore drives that loop, and `SC14-O2`'s `liveHighWater ≤ bound` is false:
the record carries `liveHighWater=5` and `parkedAtPeak=5` against `bound=2`, and the check exits 1 with
its own `Then` text:

```
SC14 Then: the live-connection bound is not held
  obligation: every live connection is within its bound (Service.Bounded)
  expected liveHighWater <= bound=2 and liveHighWater = bound
  observed: liveHighWater=5 parkedAtPeak=5 accepted=[0,1,2,3,4]
```

The violation is already in the shipped loop, so no staged revision, no ordering deviation and no
substitution exposes it. `SC14-O1` and `SC14-O3` hold on the same loop: the unbounded loop awaits
every spawned body, and the body reports `.ok` for a completed connection and an error for one that
deadlines or fails, so the id partition and the disjoint resolution both hold. Those two clauses and
`SC14-O2` are each evaluated on the record before the first failing one is reported, so a run that
also broke either of them would name it instead. A red is only a red if it is this clause's own
assertion: a missing `service|` record, a malformed record, a non-zero exit without a `fail` line, or a
watchdog expiry is a setup error, not the `Then`.

**Why, and what it rests on.** `Service.NoDrop` is the partition "every admitted connection appears
exactly once, in exactly one of live/completed/closed", so obligation 1 asks the executor's record to
show that partition for the ids it admitted, and the affirmative control is that both terminal paths
are populated rather than one carrying the whole equality. `Service.Bounded` is `live.length ≤ bound`,
and its executor counterpart is the live high-water over the mode's own `begin`/`end` annotations; the
client's deferral of every read and close until the loop's admission policy is satisfied — `bound`
begins on a loop that waits on a permit, every offered begin on one that admits unconditionally — is
what makes `liveHighWater = bound` on the bounded loop, structural rather than a timing accident
**because the client connects the self-terminating ids `1` and `3` last**: the first `bound` admissions
are therefore the echoers, which cannot end before the client's deferred first close, so the high-water
is exactly the bound; the same deferral on the unconditional loop admits all five at once, which is why
the equality is absent there. This rests on the accept queue delivering accepts in the client's connect
order — an ordering assumption, not a fact the scenario establishes. `Service.RequestsResolved` is
`responded + errored + pending.length = requests` and `Service.PendingWithinLive` keeps every pending
request on a live connection, so obligation 3 asks the record to resolve each request exactly once, and
the deadline path is exercised by id `1`'s `Runtime.never` response — an event order, not a clock: the
deadline fires with no dependence on the peer. On the shipped loop, `liveHighWater` is the offered
count, which is the bound violated, and the other two obligations are what the run still shows, which
is what makes the record evidence for all three rather than only for the clause that fails.

The checker is exercised inside the same invocation: it accepts a well-formed record and rejects near
misses whose `completed` is missing an id `accepted` holds, whose `closed` carries an id `completed`
also carries, whose `liveHighWater` is `bound + 1`, whose `liveHighWater` is `0`, whose `requests`
carries an id in neither `responded` nor `errored`, and whose `deadlineFired` is `no` with `errored`
empty. Every near miss is built from the record syntax and the expectation, never from the mode's
output, and a control that does not hold is a fixture defect rather than this `Then`. The mode's own
`servicectl|` readings must hold too: on a well-formed record the checker says `accepted`, and on each
near miss it says `rejected`. The `Then` must hold in each of the mode's three invocations.

______________________________________________________________________

### SC13 — async synchronisation: a mutex, a semaphore and a bounded channel on one carrier

**Actor.** A Lean executable client of the task layer (`lake exe controls --runtime-sync`), driving the
three primitives of `LeanIn/Task/Sync.lean` — an async mutex, an async semaphore and a bounded channel —
from computations on one `Sched.Executor.new LeanIn.Task.Item 256 1`, with `Runtime.Hooks.new` for the
fake completions.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC13`, which invokes
`lake exe controls --runtime-sync` three times and asserts on the one `sync|` record each invocation
prints, plus the mode's own `syncctl|` checker readings. Nothing here reads a private field, a queue or a
slot: every compared value is a named field of that record, and every event in its `order` field was
appended by the actor that caused it, where it happened.

**Given.** A fresh executor (`Sched.Executor.new LeanIn.Task.Item 256 1`) and a fresh `Runtime.Hooks.new`.
Two `IO.Promise (Except IO.Error Unit)` gates, resolved only by the unrelated computation's own steps — a
mutex/condvar-shaped handshake, never a timer — and a third such gate which the second holder resolves at the
start of its step, so the unrelated computation's first step is caused while the first holder still holds the
mutex. `Sync.Mutex.new`; `Sync.Semaphore.new 0` for the parked acquirers; `Sync.Channel.new k` for a bound `k`
with `sent = k + 1`, and a second `Sync.Channel.new sent` as the affirmative control. The carrier's tid is read
on the mode's own thread.

**When.** One invocation, inside one `Runtime.run`. The first holder acquires the mutex, records
`a-enter`, spawns the second holder and the unrelated computation, and awaits the first gate. The second
holder records `b-enter` only after it is granted the mutex, spawns the unrelated computation's second
step inside its own section, and awaits the second gate. The unrelated computation's first step waits on the
third gate, records `u` and releases the first gate — the only wake that ends the first holder's section — and
its second step, spawned only from inside the second holder's section, records `u` and releases the second
gate. Both holders return their own value. Then, on the channel of bound `k`: `sent` non-parking `trySend`s,
then `sent` `send`s against the full channel, each drained by a `recv` (which the parked senders wait on),
then the control channel, capacity `sent`, `sent` `trySend`s. Then the semaphore's permits: two
`tryAcquire`s, a third, one `release`, and a fourth. Then the three cancellation laws, each read from a
non-parking probe:

1. a holder takes the mutex, a waiter parks on it, the waiter is cancelled, the mutex is released, and a
   non-parking `tryLock` reads whether the permit is still there;
2. a receiver parks on an empty channel, is cancelled, one value is sent, and a non-parking `tryRecv`
   reads whether the value is still there;
3. a sender parks on a full channel, is cancelled, one value is drained, and a non-parking `trySend`
   reads whether a slot is free and whether the cancelled sender's value has appeared.

The second law's probe follows a stock completion scheduled after the send, because the receiver's value
is taken by the receiver's own stock task and that task runs on the pool; the wait is a completion, not a
clock. The mode then prints the `sync|` record, its `syncctl|` readings and its `syncbench|` line, and
returns.

**Then.** There is exactly one `sync|` record, and its fields are exactly, in this order with nonempty
values: `cap`, `order`, `aResult`, `bResult`, `sent`, `tryAccepted`, `tryRejected`, `parkedDelivered`,
`controlAccepted`, `controlRejected`, `semAccepted`, `semRejected`, `semAfterRelease`,
`cancelLockAcquired`, `cancelRecvValue`, `cancelSendGhost`, `cancelSendAccepted`, `runUs`. Records are
parsed by named key; a key absent, repeated or empty fails the check rather than resolving to another
field. `order` is a comma-separated event stream read as an ordered sequence of exactly the six events
`a-enter`, `a-exit`, `b-enter`, `b-exit`, `u`, `u`, once each; the order of the two sections relative to
each other is not asserted, and `aResult`/`bResult` are distinct values the holders returned.

**Both holders complete, and their sections do not overlap:** `aResult` and `bResult` are nonempty and
distinct, `a-enter` precedes `a-exit` and `b-enter` precedes `b-exit`, and one section lies wholly before
the other — read from the events' positions, never by comparing the whole stream to a fixed string. **An
unrelated step does not wait:** a `u` falls strictly between the first section's `-enter` and its
`-exit`. **The bound holds, exactly:** `sent = cap + 1`, `tryAccepted = cap`, `tryRejected = 1`, with the
affirmative control `controlAccepted = sent`, `controlRejected = 0`. **Every parked send is delivered:**
`parkedDelivered = sent`. **The semaphore's permits are exact:** `semAccepted = 2`, `semRejected = no`
(a third acquirer is refused), and one release admits exactly one more (`semAfterRelease = yes`). **The
cancellation law holds for each primitive:** `cancelLockAcquired = yes` (a cancelled lock waiter is not
granted the lock), `cancelRecvValue = present` (a cancelled receiver consumes no message), and
`cancelSendGhost = absent`, `cancelSendAccepted = yes` (a cancelled sender consumes no slot). `runUs` is
printed and never asserted on.

The checker is exercised inside the same invocation: it accepts a well-formed record and rejects near
misses whose `order` overlaps, whose `u` falls outside both sections, whose holder values are empty or
equal, whose accepted count is one short of the bound, whose control rejected a send, whose admitted
permit count is one, whose release admitted no one, whose cancelled lock waiter was granted, whose
cancelled receiver consumed a message, whose cancelled sender consumed a slot, and a record with nothing
to observe. Every near miss is built from the record syntax and the expectation, never from the mode's
output, and a control that does not hold is a fixture defect rather than this `Then`. The mode's own
`syncctl|` readings must hold too: on a record whose named relation is broken the checker says
`rejected`, and on a well-formed record it says `accepted`. The `Then` must hold in each of the mode's
three invocations.

**Why, and what it rests on.** The mutex, the semaphore and the bounded channel park a *computation*
rather than the carrier, and the two clauses of the acceptance are stated by the actors themselves: the
holders' `-enter`/`-exit` events carry exclusion and the unrelated `u` carries that a waiter does not
stall other work, and the exact accepted/rejected counts carry that the bound holds. On the revision
whose bodies are adapters over the stock shapes, the last two probes print `cancelLockAcquired = no` and
`cancelRecvValue = lost`: a release hands a permit to a waiter irrevocably, and a receive dequeues a
message into the task it returns, so a waiter the runtime then skips has already consumed it. A mechanism
whose wake is only a hint and whose waiter acquires in its own step prints `yes` and `present` here;
those two fields are the scenario's own outcome assertions on unfixed behaviour, and the rest of the
record holds either way. `syncbench|` is printed and never asserted.

______________________________________________________________________

### SC12 — blocking jobs run off the carrier, on a bounded pool, without stalling the executor

**Actor.** A Lean executable client of the runtime's blocking pool: four **blocking jobs** submitted through
the pool, each recording the thread it ran on, and a **heartbeat** computation whose every step is a carrier
step, so the executor has work to do while the jobs run. Nothing on the carrier blocks.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC12`, which invokes
`lake exe controls --runtime-blocking`. The check reads the one `block|` record the mode prints, and the mode's
own detached `blockctl|` detector control; nothing here calls a private function, reads a queue or a slot, or
inspects a thread table — the observation is the mode's record.

**Given.** A fresh executor (`Sched.Executor.new LeanIn.Task.Item 256 1`), a fresh `Runtime.Hooks.new`, a pool
`Runtime.BlockingPool.new 2`, four jobs, a twenty-five-millisecond `IO.sleep` each, a heartbeat of two hundred
cheap steps, and one stock task at `_root_.Task.Priority.default`. The carrier's tid is read on the mode's own
thread.

**When.** In one invocation the mode, inside one `Runtime.run`: spawns the four jobs, each
`Runtime.spawnBlocking pool hooks (jobBody i)` where `jobBody i` appends `job<i>-start`, records `IO.getTID`,
sleeps, and appends `job<i>-done`; spawns the heartbeat, whose every step appends `hb` and reads
`Runtime.pending hooks` into `pendingPeak`; submits one stock default-priority task and awaits it, recording
whether `stock` precedes the last `job<i>-done`; awaits every job, recording in each continuation the thread it
resumed on into `resumeTids`; awaits the heartbeat, then calls `Runtime.BlockingPool.shutdownAndWait pool`; and
returns. The returned unit is the synchronisation point — no clock enters any assertion — and the mode then
reads `Runtime.pending hooks` into `pendingAfter` and the pool's `exited` into `workersExited`.

**Then.** There is exactly one `block|` record, and its fields are exactly `jobs`, `carrier`, `jobTids`,
`poolWorkers`, `carrierDuringFirstJob`, `resumeTids`, `stockBeforeJobs`, `pendingPeak`, `pendingAfter`,
`workersExited` and `runUs`, in that order with nonempty values. `jobTids` and `resumeTids` are bracketed
comma-separated tid lists read with the fixture's existing bracket syntax, one tid per job in job order.

**The blocking jobs ran off the carrier:** every `jobTids` entry differs from `carrier`, and the shape cannot
be vacuous — `jobs ≥ 2` and `poolWorkers < jobs` with `poolWorkers ≥ 1`. It is a **bounded pool**, not a
thread per job: `distinct(jobTids) ≤ poolWorkers`, so four jobs shared at most two threads. `carrier` and
`jobTids` are read from the same record, so assertion 2 is not satisfied by a value appearing elsewhere in the
output, and `distinct` is computed rather than read. `carrierDuringFirstJob = yes` says the executor was **not
stalled** — the recorded event order carries a carrier `hb` step strictly between the first job's start and its
completion — and `resumeTids` all equal to `carrier` says every completion was delivered back on the carrier,
so nothing of ours ran on a job thread. `stockBeforeJobs = yes` says the stock pool was left untouched.
`pendingPeak = jobs` and `pendingAfter = 0` are the accounting: the runtime's outstanding-registration reader
saw every job while they were outstanding and none after the run returned and the pool was shut down, the first
being the affirmative control that makes the second a claim rather than an unbacked absence. `workersExited =
poolWorkers` says the pool's own shutdown drained and every worker exited. `runUs` is printed and never
asserted on.

The detector is exercised inside the same invocation: it accepts a well-formed record and rejects nine near
misses, among them `jobTids` all equal to `carrier` — the shape blocking jobs run to completion on the carrier
produce — four distinct `jobTids`, `carrierDuringFirstJob=no`, a completion resumed off the carrier,
`stockBeforeJobs=no`, `pendingPeak=0`, `pendingAfter=1`, a worker short of `poolWorkers`, and a record with
nothing to observe. Every near miss is built from the record syntax and the expectation, never from the mode's
output, and a control that does not hold is a fixture defect rather than this `Then`. The mode's own
`blockctl|` readings must also hold: the distinct-thread detector counts two on two distinct tids and one on a
repeat, the order detector rejects the blocking-shaped order `job0-start,job0-done,hb` and accepts the
interleaved `job0-start,hb,job0-done`, and the stock guard rejects a record that says the stock pool was taken.
The `Then` must hold in each of the mode's three invocations.

**Why, and what it rests on.** The executor has one carrier, so `IO.sleep` — and every synchronous leaf — blocks
it. The pool moves that work to dedicated threads (`Task.Priority.dedicated` is above `Task.Priority.max`),
bounded by the caller's width rather than one thread per job, and assertion 2 is the off-carrier claim itself
while `carrierDuringFirstJob` and `pendingPeak` read the same defect from the executor's and the registry's
side. The order reading is the actors' own annotation order rather than elapsed time, which is why the scenario
can state that a carrier step fell inside the first job's start→completion without reading a clock: on the
unfixed route the job is one carrier step, so its start and completion are adjacent in the log.

______________________________________________________________________

### SC11 — a disconnect cancels the work, and no step of it runs afterwards

**Actor.** A Lean executable server, one process, three actors on one executor: a **work** computation that counts
once and then parks on a leaf it does not own; the **watcher**, which is the run's own computation — it accepts the
first connection, waits for the peer to leave, and in that same step reads the counter and cancels the work; and a
**second connection**, which the client opens after the cancellation and which is echoed.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC11`, which invokes
`lake exe controls --runtime-cancel`. The cancellation is a public operation on a handle, and the check reads the
one `cancel|` record and nothing else.

**Given.** A fresh executor, a listener bound to `127.0.0.1:0`, a work computation spawned before the watcher's
first step, a leaf the work parks on that the watcher resolves *after* it cancels, and a second leaf that is never
resolved.

**When.** The client connects and closes. The watcher's read on that connection reports end of stream — the
disconnect — and in the same step it reads the counter into `counterAtCancel` and requests the cancellation, then
resolves the first leaf. That leaf's completion resumes the work's step, which is exactly the step the cancellation
is meant to stop. A second client then connects, sends, and reads its echo. The run returns, and the counter is read
again into `counterFinal`.

**Then.** There is exactly one `cancel|` record, and its fields are exactly `disconnect`, `second`,
`counterAtCancel`, `counterFinal`, `pendingAtCancel`, `pendingAfterCancel`, `cancelled`, `doubleCancel` and
`runUs`, in that order with nonempty values.

`counterAtCancel = counterFinal` is the assertion: **no step of a cancelled computation runs after the cancellation
was requested.** It is the abort law rather than a timing claim — the counter is read inside the cancelling step and
again after the run returns, so no clock enters it, and because the leaf is resolved after the cancellation, the
resumed step is one that would otherwise have run. `counterAtCancel ≥ 1` forbids the vacuous reading: a run in which
the work had not started would satisfy the equality with `0 = 0` and prove nothing. `pendingAtCancel = 1` says a
registration of the work really was outstanding when the cancellation arrived; `pendingAfterCancel = 0` says it is no
longer counted as work in flight. `cancelled = canceled` is the handle's awaiter waking with the cancellation rather
than parking for a value that will never come, and `doubleCancel = ok` is the first-writer law holding when a second
cancellation arrives. `second = yes` folds in W5's second clause: a connection served *after* a cancellation is
unaffected by it. `runUs` is printed and never asserted on.

The detector is exercised inside the same invocation: it accepts a well-formed record and rejects nine near-miss
records, among them `counterFinal` one past `counterAtCancel` — the shape production prints while nothing consults
the token — and `pendingAfterCancel=1`. Every near miss is built from the record syntax and the expectation, never
from the mode's output, and a control that does not hold is a fixture defect rather than this `Then`.

**Why, and what it rests on.** Cancellation here is *ours*, because Lean offers no other stopping power. The
runtime's own documentation is explicit that a task created by `IO.bindTask` "will run even if the last reference to
the task is dropped" (`Init/System/IO.lean:266-269`), and a search of the whole `Std` tree finds `IO.cancel` and
`IO.checkCanceled` in one test helper and nowhere a socket or timer would observe them. A leaf therefore cannot be
cancelled, and the gate is placed where a step is run: a step whose token is set does not execute, whether it was
enqueued before the cancellation or after it.

The two counted operands are read about *this* computation's registrations rather than about the runtime's, because
the runtime's total includes the cancelling computation's own and is not stable at the moment of a read — a
cancelling step is itself a resumed continuation, and whether its registration is already marked finished is another
thread's business. `pendingAtCancel` is the work's own registration, outstanding because the work is parked on the
leaf the watcher has not resolved yet. `pendingAfterCancel` is the same count read *in the cancelling step,
immediately after the cancellation*: it is `0` because the cancellation retired the entry, which is what makes that
reading the one that discriminates the retirement half. The gate's half is what the counter is for — with the gate
missing, the resumed step runs and the counter advances.

______

### SC10 — a stop drains: the connection in flight completes, and nothing is left outstanding

**Actor.** A Lean executable server that accepts one connection and echoes it, with the connection itself stopping
the executor from inside the body being served. The client is `Std.Async`'s: it connects, sends, reads its echo
and closes.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC10`, which invokes
`lake exe controls --runtime-drain`. The stop is a public executor operation; the check reads what the run recorded
and the two counts it read back afterwards.

**Given.** A fresh executor, a listener bound to `127.0.0.1:0`, and a 9-byte payload.

**When.** In one invocation the server's accept loop polls, accepts the connection, and the body — before echoing —
stops the executor. The loop notices on its next poll, stops accepting, and waits for the connection it already
has. The client reads its echo and closes, which ends the connection; the drain then returns, and the run returns
the loop's own value.

**Then.** There is exactly one `drain|` record, and its fields are exactly `served`, `echoed`, `inFlightAfter`,
`pendingHooks`, `listener` and `drainUs` in that order with nonempty values.

`served` is `1` and `echoed` is `yes`: the connection that was in flight when the stop arrived **completed** — its
echo came back to the client — which is what "a stop drains" means and what W5's acceptance asks for.
`inFlightAfter` is `0`: the pool holds nothing once the run returns. And `pendingHooks` is `0`: **no leaf
registration is left outstanding.** That last field is the one no model of pool items could state, because a task
parked on a leaf holds no pool item at all — a driver that stopped there would abandon the continuation without
disturbing any counter, which is exactly the bug this scenario was written to catch.

The detector reading those four conditions is exercised inside the same invocation: it accepts a well-formed
record and rejects four near misses — a connection dropped by the stop (`echoed=no`), a pool still holding work, a
registration left outstanding, and a run that served nothing. Every near miss is built from the record syntax and
the expectation, never from the executable's output, and a control that does not hold is a fixture defect rather
than this `Then`.

**Why, and what it cost.** Two bugs came out of writing it, both in the driver rather than in the sockets.

*The stop abandoned instead of draining.* `Runtime.blockOn` ended the driver as soon as the pool was empty and the
executor was stopping — but a stopped executor still holds work as continuations registered on leaves, which are
not in the pool by construction. So `Runtime.run` threw "the driver stopped before the computation finished", the
connection's continuation was never resumed, and a client waiting on it hung in `recv`. The model's shutdown says
*drain*; the driver aborted, and running it is what showed the difference.

*Then the wait was not a wait.* The fix had `blockOn` park directly, without recording that it was parking — and
`submit`/`spawnBase` notify **only when `parked ≠ 0`**. So the driver slept with the loop's poll timer pending, the
timer completed and enqueued the loop's continuation, and nothing told the driver. It now sets `parked` before
waiting and clears it on waking, the way `Executor.work`'s predicate does. That is the protocol, and skipping it
was invisible until a scenario had work in flight when the stop arrived — which is why this is a scenario and not a
diagnostic.

The first version of the mode also died with `104 connection reset by peer`, for the reason SC9 records: a socket's
descriptor dies with the last use of the object owning it, and the loop's final `tryAccept` is not the end of the
run. The listener is read again after the drain for that reason.

______

### SC9 — a failed socket operation arrives as a value, and the listener must outlive its last use

**Actor.** A Lean executable client that connects twice: once to a port nothing listens on, and once to a
listener the same program holds. The second is the affirmative control for the first.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC9`, which invokes
`lake exe controls --runtime-connect`. Nothing is accepted in this mode — the point is the connect, not a
conversation — so the check reads the two outcomes and the listener's own address and nothing else.

**Given.** A fresh executor, a listener bound to `127.0.0.1:0`, and two `connect`s through the runtime's own
wrapper, which returns failures as values.

**When.** In one invocation the client connects to port 1, which nothing user-level can be listening on, and then
to the listener's address, which it reads in the same step. It prints the refusal text, the second outcome, and
the listener's address read again afterwards.

**Then.** There is exactly one `connect|` record, and its fields are exactly `refused`, `accepted` and `listener`
in that order with nonempty values.

`refused` is the *refusal* — its text carries `error code: 111`, and it arrived as a value, so the run reached
its own record rather than dying. `accepted` is `ok`: a connect to a live listener succeeds, which is what makes
the refusal a reading rather than a reader that reports failure for everything. And `listener` is non-empty,
because the socket had to still exist at the end for either of the first two to mean anything.

The detector reading those three conditions is exercised inside the same invocation: it accepts a well-formed
record and rejects three near misses — an accepted connect that also failed, a refusal reported as success, and a
listener that did not survive the run. Every near miss is built from the record syntax and the expectation,
never from the executable's output, and a control that does not hold is a fixture defect rather than this `Then`.

**Why, and what it cost to learn.** `interface.md` §5 records that our `Async` has no error channel; `EAsync` is
that channel, and this is the first scenario that reads it — a socket failure has to be an ordinary value,
because a client closing a connection mid-request is the normal case for a server.

The scenario also carries a rule that only showed up by writing it. **A socket's descriptor dies with the last
*use* of the Lean object that owns it, not at the end of its scope.** The first version read the listener's
address immediately before connecting and the listener was collected in between, so the connect was reset by a
socket that had just served sixteen connections; two of four runs died with SIGSEGV instead, which is the same
hazard winning a different race. Keeping the listener in a reference whose own last use falls *after* the connect
holds both alive through it, and six consecutive runs then read `refused=…111`, `accepted=ok` and a bound
listener. That is a rule the driver obeys for its listener and for every connection it serves, and it is here
rather than in the driver because this is the smallest place it can be seen.

______________________________________________________________________

### SC8 — timers on our carriers: sleeps that park rather than occupy, and timeouts that fire

**Actor.** A Lean executable client of LeanIn's timer leaf and its timeout combinator: `16` sleepers of 50 ms
each as steps of one executor driven by one thread, a task spawned while all of them are pending, and two
`withTimeout` calls whose inner computations are chosen so that the outcome is not a matter of timing.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC8`, which invokes
`lake exe controls --runtime-time`. The sleeps and the timeouts are the public operations; the check reads the
event order the client recorded where the events happened, plus the two outcome values, and nothing else.

**Given.** A fresh executor, `16` sleepers on a 50 ms timer, one extra task spawned after them, one inner
computation that never finishes, and one that finishes immediately.

**When.** In one invocation the client spawns the sleepers, spawns the late task, awaits all of them, and then
runs the two timeouts. Each sleeper records `start:i` before it sleeps and `wake:i` after; the late task records
that it ran.

**Then.** There is exactly one `time|` record, and its fields are exactly `sleepers`, `overlap`,
`lateBeforeWake`, `wakes`, `timeoutHit`, `timeoutMiss`, `firstWins`, `lateTimerIgnored` and `sleepUs` in that
order with nonempty values.

`overlap` is `true`, and it is the whole point: **every one of the `16` starts precedes the first wake**, so the
sleeps parked on the timer rather than occupying the carrier. That is the clock-free form of "they finish in
about `d`, not `N × d`" — an implementation that slept on the carrier would wake the first sleeper between the
first two starts, and this reading would be `false`. `lateBeforeWake` is `true`: the task spawned while every
sleeper was pending ran before the first wake, which is the same fact seen from the other side. `wakes` equals
`sleepers`, so every sleeper did wake, and `timeoutHit` is `none` while `timeoutMiss` is `some:7` — the inner
computation that never finishes times out, the one that finishes immediately does not, and neither outcome
depends on how long a run takes.

`firstWins` and `lateTimerIgnored` are the task layer's first-writer law, which is the only thing W3 added to
it, and they are recorded rather than left to the timeout cases above. `firstWins` is `some:1`: two writes to one
cell were issued **in order** — not raced, because which of two racing writers wins is a scheduling fact and
this is a claim about the operation — and the value that arrives is the first, with the second ignored.
`lateTimerIgnored` is `some:7`: a `withTimeout` whose computation finished immediately, followed by a 40 ms sleep
against a 5 ms deadline, so the timer *does* fire — inside the run, after the winner wrote — and the value is
still the computation's. The reachable defect is exact: the loud `Join.resolve` in either position would raise
out of the driver instead, so reaching the record at all is part of the evidence, and the near misses for this
detector are a first value that was overwritten and a late timer that overwrote the winner.

`sleepUs` is printed and never asserted, for the reason SC7 gives.

The detector reading those seven conditions is exercised inside the same invocation: it accepts a well-formed
record and rejects seven near misses — `overlap=false`, `lateBeforeWake=false`, `wakes` one short, each timeout
outcome swapped, `timeoutMiss=none`, a `firstWins` of `some:2` where the second writer overwrote the first, and a
`lateTimerIgnored` of `none` where the timer overwrote the winner. Every near miss is built from the record syntax and the expectation,
never from the executable's output, and a control that does not hold is a fixture defect rather than this
`Then`. The executable's own two controls are read from its `timectl|` record and required to hold: its overlap
detector reads `false` on a deliberately blocking-shaped order (`start,wake,start,wake`), and its wake counter
reads one fewer than `sleepers` when a wake is removed — the second derived from the record's own `sleepers`
field rather than retyped.

**Why.** A timer is the leaf a service leans on for every deadline it has, and the claim being checked is not
that a clock advanced but *where the waiting happened*: on libuv's loop, with the carrier free. Reading that
from the recorded order rather than from elapsed time is what makes the check survive a loaded machine — and it
is why the one block that does measure is printed rather than asserted, and why the first version of this
detector, which demanded that everything before the first wake be a start, was caught by its own control rather
than by the `Then`.

______________________________________________________________________

### SC19 — one HTTP request over a real loopback socket: a byte-exact response, on our carrier

**Actor.** A client that connects to a loopback listener this invocation binds itself, and sends one request
line `GET / HTTP/1.1` with `Host` and `Connection: close`. The client is deliberately **not** ours: `Std.Async`'s
TCP client, driven by `Async.block` on the calling thread.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC19`, which invokes
`lake exe controls --runtime-http`. The listener is bound by the invocation itself (`Runtime.loopback 0`), so the
socket is inside the boundary rather than an external network service; nothing in the check reaches into a queue,
a slot, a thread table or a byte buffer of the executor.

**Given.** A fresh executor, a listener bound to `127.0.0.1:0` — the OS chooses the port and the client is told
what it chose — one accepted connection, and the request above, whose body is empty. The server answers with a
pinned response: status `200`, `Content-Length: 5`, and the five-byte body `hello`.

**When.** In one invocation the server accepts the connection and runs its per-connection loop, and the client
connects, sends its one request and reads until the peer closes. The bytes the client read, the thread ids the
server-side work ran on and the executor's holdings are reported in one `http|` record; the executor's observer is
read twice: before the driver starts, with three no-op items deliberately queued, and again after the driver
returns.

**Then.** There is exactly one `http|` record, and its fields are exactly `method`, `uri`, `status`, `got`,
`carrierThreads`, `clientAmongServer`, `heldBefore`, `inFlightAfter` and `pendingHooks` in that order with
nonempty values.

`got` is the bytes the client actually read, escaped so the field stays one token — `\`→`\\`, CR→`\r`, LF→`\n` —
and it equals the fixture-owned literal `SC19_EXPECTED`, which was derived by driving a fresh
`H1.Machine .receiving` with the same request and response and escaping the bytes it produced, rather than typed
by hand. `method` is `GET`, `uri` is `/` and `status` is `200`, so the record's own parse of the exchange is
pinned too.

`carrierThreads` is `1`: the server-side work ran on one thread — the single-carrier claim, measured where the
work happened rather than inferred from the configuration. `clientAmongServer` is `false`: that thread is not the
client's, so what is asserted is where *our* work ran rather than that only one thread existed. `inFlightAfter`
is `0`: nothing the connection owed is held once it has been served. `pendingHooks` is bound by its own named
field — so a record whose shape lost it is rejected — and compared nowhere: the read that won this request's
bytes leaves `withTimeout`'s loser timer registered until it fires with nobody waiting, one timer per read that
won, so its value is the race's relic rather than this driver's behaviour; it reads `1` here, and the timer
retires later on the live clock, after the record is taken. `heldBefore` is non-zero — the affirmative control
for the held-work reading, since the observer is the same one on both sides and a reader that cannot see work
would report zero either way.

The detector reading those conditions is exercised inside the same invocation. It accepts a well-formed record
and rejects five near misses — `got` with one byte appended, `got` with its `\r\n` rewritten to `\n`, `status=404`,
`clientAmongServer=true`, and `inFlightAfter=1` — each built from the record syntax and the expectation, never
from the executable's output, with a control that does not hold reported as a fixture defect rather than as this
`Then`. The executable's own tid-detector control is read from its `httpctl|` record and required to hold: the
distinct-thread detector counts two on a two-distinct sample and collapses a repeat, so it is not stuck at the
value the `Then` wants.

**Why.** A server that has to run on our carriers owns its loop, and that loop is the deliverable: a driver of
ours over `LeanIn.Http.H1`'s machine, whose accept loop is reused from `Net.lean`. The two things checkable
from outside are the bytes the peer read and *where* the work ran, and a thread identity is the only way to check
the second. The byte comparison is what keeps the first honest — a runtime that answered from another protocol
version, another framing or another body could still report a plausible status line. The limits are this
milestone's: one request per connection, no request or response body beyond the `Content-Length`-framed literal,
no TLS, no routing, and keep-alive only as `LeanIn.Http.H1.Limits` gives it (`maxMessages`, the keep-alive quota it shares with the parser it replaces). The driver bounds each wait for request bytes
with `Config.stallTimeout` through `Runtime.withTimeout` (D20), so this scenario's single read is bounded like every
other read, and the losing timer that bound leaves is the relic noted above.

______________________________________________________________________

### SC20 — a connection serves more than one request, a failing handler is answered, and a stalled peer ends at a stated instant

**Actor.** A client that this invocation binds a listener for and connects to three times — deliberately **not**
ours: `Std.Async`'s TCP client, driven by `Std.Async.Async.block` on the mode's own thread, as SC19's is. The
server side is `Runtime.Http.serveConn` under `Runtime.serveNJoin`, the accept loop of ours.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC20`, which invokes
`lake exe controls --runtime-http-service`. The listener is bound by the invocation itself
(`Runtime.loopback 0`), so the socket is inside the boundary rather than an external service. No fake transport,
no faked clock reading and no network service is involved: the sockets are real, the accepted connections are
real, the machine is `LeanIn.Http.H1`'s — the connection driver's own parser and machine, not a fake — and the only non-production device is `HarnessClock` in clause three,
which SC17's clause three already uses.

**When.** One invocation runs three clauses, each with its own listener and its own run.

1. **Clause one — keep-alive (`ka|`).** One client socket: connect, send
   `GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n` — **no** `Connection` header, so the machine's own `enableKeepAlive`
   stands — read until the accumulated bytes equal the pinned keep-alive response, send the *same* request again on
   the same socket, read until they equal it again, then shut the socket down. The record is
   `ka|handled=<the requests the handler answered>|first=<escaped response 1>|second=<escaped response 2>|carrierThreads=<n>|clientAmongServer=<b>|heldBefore=<n>|inFlightAfter=<n>|pendingHooks=<n>|runUs=<n>`.
2. **Clause two — a failing handler (`fa|`).** A second listener and run in the same invocation, whose handler
   **suspends first** — one millisecond on the server clock — and only then returns `error` for every request, so
   the failure is raised in a *resumed* continuation rather than in the extent the handler was first called in.
   The client sends the same request and reads until end of stream. The record is
   `fa|status=<the code the client parsed out of the status line>|got=<escaped bytes read>|carrierThreads=<n>|heldBefore=<n>|inFlightAfter=<n>|pendingHooks=<n>|runUs=<n>`.
3. **Clause three — a stalled peer (`idle|`).** A third listener and run, driven by
   `IO.asTask (Runtime.runVirtual hc e prog)` on its own thread, with `cfg.clock := HarnessClock.clock hc` and
   `cfg.stallTimeout := 30` — the mode's stated instant, `stall`. The client connects and **never sends a byte**,
   then reads under the invocation bound and closes if it fires. Once that run has returned the mode waits for one
   queued step, bounded in live time, and fires it before it reads its executor, so the holding in the record is
   taken after the losing read arm's own step has run. The record is
   `idle|stall=<stated ms>|at=<hc.now after the run>|pendingAfter=<hc.pending>|clientGot=<escaped bytes, empty>|bounded=<yes|no>|carrierThreads=<n>|clientAmongServer=<b>|heldBefore=<n>|inFlightAfter=<n>|pendingHooks=<n>|runUs=<n>`.

**Then.** Each clause has its own record, its own detector and its own `Then`, evaluated in the order O1, O2, O3,
and the tid control's `connctl|` reading after them, so the first assertion a run reports is never
interleaving-dependent. A clause's record is bound by its own named fields; `first`, `second`, `got` and `clientGot`
are bound by the same rule with the empty string allowed, because a clause that reads nothing is one of the
outcomes this scenario must be able to observe.

- **SC20-O1.** `handled == 2`; `first == SC20_RESPONSE` and `second == SC20_RESPONSE`, where `SC20_RESPONSE` is
  the fixture-owned literal derived by driving a fresh `H1.Machine .receiving` with this request and the pinned
  `200`/`Content-Length: 5`/`hello` head, escaped the way the executable escapes a client's bytes (`\`→`\\`,
  CR→`\r`, LF→`\n`) — it carries **no** `Connection` header, unlike SC19's, because nothing asked for a close;
  `carrierThreads == 1` and `clientAmongServer == false`; `inFlightAfter == 0` and `heldBefore != 0`. `pendingHooks`
  is printed in the record and asserted in no clause — it counts `Runtime.withTimeout`'s leftover timers rather
  than this driver's behaviour, and this clause's own reading of it is 3 (the two request reads and the end-of-stream
  read that ends the clause, one registration each). The second exchange is the discriminator: a connection closed
  after the first response cannot produce a second one.
- **SC20-O2.** `status == 500` and `got == SC20_FAILURE`, the derived literal of the machine's own
  `closeWithError .internalServerError` shape; `carrierThreads == 1`; `inFlightAfter == 0` and `heldBefore != 0`,
  with `pendingHooks` printed and asserted in no clause (this clause's reading of it is 1 — the one request read
  that won — and once in 60 runs of the mode it read 2, which is why the field is a reading and not an assertion).
  The failure response is followed by the write side shutting down, which is what ends the client's read.
- **SC20-O3.** `at == stall` with `stall != 0` — a relation between two stated values, not a constant compared
  against a literal — `clientGot` empty and `bounded == no`, so the end the client read came from the server's own
  deadline and not from the client giving up; `pendingAfter == 0` (the timer fired, and no other is outstanding in
  the timer list — the clause where the timer itself resolved the read); `carrierThreads == 1` and
  `clientAmongServer == false`; `heldBefore != 0`; and `inFlightAfter == 0`, read **after** the mode has driven its
  executor once past the run — the deadline beat the read, so the losing read arm's step is still queued once the
  run has returned, and the mode waits for that one step (bounded in live time) and fires it before reading. The
  leftovers are set out below. This clause is also the only evidence that the loop reached its read and
  parked there: a loop that spun instead would schedule no timer, so the harness clock would never advance and `at`
  would read `0`.

**Why it is not vacuous.** Four affirmative controls are in the same run. The distinct-thread detector that reads
every `carrierThreads` is shown, in `connctl|`, counting two on a two-distinct sample and collapsing a repeat, so a
`1` is a reading rather than a stuck counter — and a control that does not hold is reported as a fixture defect,
separately from the `Then`. Clause one's `first` and `second` are read by the same client helper and the same read
path that clause three uses and finds empty, so clause three's emptiness is an absence with a positive control in
the same run. Clause three's `stall`/`at` pair is a relation between two stated harness instants, with `at = 0` as
the near miss the detector must reject. And each clause's `heldBefore != 0` shows that the observer reporting
nothing held was itself holding three items when it was read. Each detector is exercised before its record is read:
it accepts a record written from the record syntax and the expectation, and rejects the near misses its clause is
built to tell apart — for O1 one served exchange, a second response that asked for a close (SC19's response), a
response with one byte appended, a client on the server thread, a task left in flight; for O2 a `200`, a response
with one byte appended, a response whose `\r\n` was rewritten to `\n`, a task left in flight; for O3 a run that never
reached the stated instant, a client that read a byte, a client that gave up first, a timer left outstanding.

**The two leftovers, and why no clause asserts the count of them.** `Runtime.withTimeout` never cancels its loser,
on either side, and this milestone does not change that: cancelling a raced loser is a cancellation decision over
`Runtime/Time.lean` — a primitive's own item, and one that would make these clauses assert the timer machinery
rather than the driver. What the race leaves is a relic on whichever side lost, and the records read it:

- **Where the read won, the timer stays registered.** A `withTimeout` whose read won leaves its sleep arm's timer
  registered until it fires with nobody waiting, so `pendingHooks` reads one registration per read that won: clause
  one 3 — the two request reads and the end-of-stream read that ends the clause, one registration each — clause two 1
  (the one request read; the failure answer halts the machine, so there is no end-of-stream read), and clause three
  0, because the timer that resolved *that* read is the harness clock's, whose sleep registers no hook at all. The
  count is a reading of the instant it is taken rather than a quantity a clause can assert — clause two read 2 once
  in 60 runs of the mode and 1 in the other 59, because the connection's own last await can still be in flight when
  the record is read — so `pendingHooks` is printed in all three records and compared in none.
- **Where the timer won, the read arm's step is left queued.** The deadline beats the read in clause three, so the
  losing read arm is still parked on its socket leaf when the run returns; the peer's socket closing then completes
  that read on the loop's own thread, which enqueues the arm's continuation — the item's own token is the losing
  arm's — and nothing takes it, because the run has already returned. That queued step is what `inFlightAfter` reads
  as 1 while it is there. The mode now waits for one queued step past the run (bounded in live time, because that
  socket completion lands after the run returns) and fires it before reading, so the value this clause asserts is 0;
  firing it runs the losing arm's own tail — a `resolveFirst` the race has already decided — and enqueues nothing.
- **What that establishes, and the guard it keeps.** The step left behind is the race's loser and not live
  connection work: it is attributed to the losing arm's own token, the connection loop's own continuation is a
  different computation — the connection body's token — which has already been consumed, and firing the leftover
  writes nothing, schedules no timer and queues no second step. Live connection work left queued by a run's exit
  would be work dropped against `Service.NoDrop`, and that is a defect this clause must report rather than a reading
  it may print away; the assertion is kept only because the leftover is the loser's own step.

**The bound, and what it does not bound.** One deadline, in one place: it wraps the read for request bytes, so a
peer that sends nothing, one that stops mid-head and one that idles between requests are the same case — the socket
gave no byte within the bound. On expiry the connection ends with **nothing written**: the peer may not have sent a
request at all, so answering `408` would be a claim about a request we may not have received. The residual limit is
stated rather than hidden: a peer that sends one byte before each deadline keeps a connection alive indefinitely,
because the total time to a complete head is not bounded, and the shipped server's cumulative per-head deadline is
deliberately **not** carried — under `runVirtual` the harness advances while our read leaf is parked, so a virtual
timer always beats a real socket read, and a clause whose point was "the peer's bytes arrive, then it stalls" would
be decided by scheduling rather than by the code. The bound is not a deadline for the handler or for the accept
either: a handler that never returns is unbounded, and `Listener.accept` is the accept loop's leaf.

**Two further limits, stated.** A handler's failure is **answered, not re-raised**: the accept loop discards each
connection's result (`Task.Registry.joinAll` awaits with `let _ ← Async.await h`), so the observable is the bytes
the peer gets, and a caller that needs the exception records it in its own handler. And pipelining — a request whose
bytes are already buffered when the next read would have happened — is a **consequence** of the connection loop and
not a claim of this scenario: SC20's client is sequential and asserts nothing about it. The client's own reads are
bounded in live time; that bound is an invocation bound so that no clause can hang, and it is never the relation a
clause asserts — which is exactly why clause three, and only clause three, records whether it fired. When it fires
the client closes its write side, which is what ends the peer's read, and the mode then drives its own loop in
bounded rounds until that run returns, so the clause records the peer's behaviour rather than hanging on it. That
drive ends a *bounded* clause; the drive the leftovers paragraph describes runs after the run has already returned,
in every clause-three run, and exists so that the holding the clause reads is taken past the losing read arm's
queued step rather than with it still in the queue.

______________________________________________________________________

### SC7 — sockets on our carriers: one server thread, and a client that is not on it

**Actor.** A Lean executable server that binds a loopback socket, accepts `16` connections through an accept
loop of its own, and echoes each one until the peer stops — all as steps of one executor driven by one thread —
with a client that is deliberately **not** ours: `Std.Async`'s TCP client, driven by `Async.block` on the
calling thread.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC7`, which invokes
`lake exe controls --runtime-net`. The client connects over a real socket, and the server reads and writes
through the public socket operations only; nothing in the check reaches into a queue, a slot or a thread table.

**Given.** A fresh executor, a listener bound to `127.0.0.1:0` — the OS chooses the port and the client is told
what it chose — `16` concurrent client connections, and a 20-byte payload each connection sends and expects
back byte for byte.

**When.** In one invocation the server accepts and serves, and the client connects, sends, reads and shuts
down; every connection task records the thread it started on. The executor's observer is read twice: before the
driver starts, with three no-op items deliberately queued, and again after the driver returns.

**Then.** There is exactly one `net|` record, and its fields are exactly `connections`, `serverThreads`,
`clientAmongServer`, `echoes`, `heldBefore`, `inFlightAfter` and `wallUs` in that order with nonempty values.

`serverThreads` is `1`: the accept loop and all sixteen connection tasks ran on one thread — the single-carrier
claim, measured where the work happened rather than inferred from the configuration. `clientAmongServer` is
`false`: that thread is not the client's, so the client's driver is genuinely a second thread in the picture,
and what is asserted is where *our* work ran rather than that only one thread existed. `echoes` equals
`connections`: every reply was byte-identical to its request, so the loop read and wrote rather than closing on
an empty read. `inFlightAfter` is `0`: nothing is left held once every connection has been awaited. And
`heldBefore` is non-zero — the affirmative control for that last reading, since the observer is the same one on
both sides and a reader that cannot see work would report zero either way. A first attempt at this control read
the observer from inside a running connection body and got `0`, which is why it now stages the queue instead: a
carrier drains the pool as it goes, so a reading taken while one is running is legitimately empty.

The detector reading those five conditions is exercised inside the same invocation. It accepts a well-formed
record and rejects four near misses — `serverThreads=2`, `clientAmongServer=true`, `echoes` one short of
`connections`, and `inFlightAfter=1` — each built from the record syntax and the expectation, never from the
executable's output, with a control that does not hold reported as a fixture defect rather than as this `Then`.
The executable's own two detector controls are read from its `netctl|` record and required to hold: the
distinct-thread detector counts two on a two-distinct sample and one on a repeat, and the reply comparison finds
nothing against a payload with one extra byte — so neither detector is stuck at the value the `Then` wants.

**Why.** W10's survey found that the shipped server's accept loop is a stock `Task`, which cannot be moved onto
our carriers, so a server that runs here owns its loop; that loop's only interesting claim is *where* it runs,
and a thread identity is the only way to check it from outside. The echo is what keeps the claim honest — a
runtime that closed each connection before reading it, or that accepted on one thread and served on another,
could still report a plausible connection count. `wallUs` is printed and never asserted: it moved by a factor
of two between runs of the same invocation, which is why this check reads identities and counts and not clocks.

______________________________________________________________________

### SC6 — real work runs on one carrier, and a pool worker only ever enqueues

**Actor.** A Lean executable client running a program on the single-carrier runtime.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC6`, which invokes
`lake exe controls --runtime-threads`. The client drives `Runtime.blockOn` on the thread it was started on,
and reads the thread identity *inside* every step the runtime ran.

**Given.** A fresh runtime, and a program that spawns a child, awaits it, awaits a second value delivered by a
stock `Task` completing on a pool worker, and reads its own thread identity in each body.

**When.** The client drives the runtime on the calling thread until the program's value arrives. No
`IO.asTask` in this mode belongs to the runtime; the one that exists is the external completion.

**Then.** There is exactly one `exec|runtime|` record, and its fields are exactly `caller`, `steps`,
`external`, `value` and `remaining` in that order with nonempty values.

`steps` is the thread each task step ran on, in order, and **every entry equals `caller`** — the driver, the
spawned child's body and the continuation that resumed after the external completion are one thread.
`external` is the thread the completion ran on and is **not** `caller`: the measurement is not vacuous,
because a second thread was in the picture, was observed, and only enqueued. `value` is the program's own sum
of what the child returned and what the external completion delivered, and `remaining` is 0.

The "every step ran on the carrier" detector is exercised inside the same invocation: it accepts a step list
of one thread and rejects a list carrying another, which is the near miss a runtime that quietly handed a body
to the pool would produce. A control that does not hold is a fixture defect reported separately from the
`Then`.

**Why.** "One carrier" is a claim about where our code runs, and a thread identity is the only way to check it
from outside. It is worth separating from "there is only one thread": the external completion genuinely runs
elsewhere — that is what the O3 bridge is for — and what this check asserts is that nothing *of ours* runs
there.

______________________________________________________________________

### SC5 — the bounded ring, the LIFO allowance and the overflow keep every staged identity

**Actor.** A Lean executable client of LeanIn's public queue and task scheduling operations.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC5`, which invokes
`lake exe controls --executor-queue`. The client stages, takes and locally spawns work through the
public queue and scheduling operations only — it writes no ring, slot or counter of its own — and the
check reads no private state either: it reads the receipts that client recorded at those operations.

**Given.** A fresh queue, the distinct staged identities `0..256`, `300`, `301` and `400..403`, and
one ordered script of two phases. In the first phase the client submits all of `0..256` before taking
any and then drains that whole batch: the 257 submissions fill a 256-slot ring, so the last of them
crosses its capacity, and the batch's take receipts are the older half the ring kept and the identity
that crossed it, followed by the newer half the overflow moved to `inject`. The second phase is a fresh tick that begins only once the first batch
has been drained: there the client stages `300` and `301` as FIFO queue work, and the root client
locally `spawn`s `400` through the public scheduling operation, and each executing body locally
`spawn`s the next of `401..403`, so those four continuations become ready on the current worker in
that tick. Local `spawn` is the operation that enqueues ready work on the current worker and wakes
it; the worker's `wake` operation un-parks only and places no work, so a slot populated through
`wake` is not this check's subject — and a client that wrote ring, slot or counter itself would not
be exercising the public operations at all.

**When.** In one scripted invocation the client first submits the 257 identities of `0..256` and
drains that whole batch, then, in a fresh tick after that drain, stages `300` and `301` and drives the
chained local spawns in that tick, recording each phase event at the action that produced it — the
drained batch, the fresh tick, the two stagings, the root spawn — alongside each identity where it
stages or spawns it, each identity from inside the body that runs it, each take receipt where the take
returned it, and each slot observation from the scheduler at the decision itself — never from a list
of what it expected to see. The ordered script is the sole source of the two phases' order; no clock
or sleep decides it.

**Then.** There is exactly one `exec|queue|` record, and its fields are exactly `staged`, `phase`,
`fifo`, `lifo`, `flush`, `slotBefore`, `delivered` and `remaining` in that order with nonempty values,
so every value is bound from one parsed invocation rather than from anywhere it appears.

`phase` is exactly `batch-drained,tick-start,stage:300,stage:301,spawn:400` — the client's own events,
in the order it recorded them where they happened. `batch-drained` is recorded only after all 257 of
the first batch's takes have returned their receipts, `tick-start` marks the fresh tick, `stage:300`
and `stage:301` are the two FIFO stagings in that tick and `spawn:400` is the root local spawn. The
stream is read as an ordered sequence, so a stream carrying the same five events with either staging
ahead of `batch-drained` — the early staging this assertion exists to catch — fails here even when the
first batch's `fifo`, the slot observations and the final `staged` and `delivered` sets all look
right.

`fifo` is exactly `0..127,256,128..255` — the take receipts of the batch that crossed capacity. That
is the model's own rule: `cap` is 256 and the placement rule `Pool.submit` uses keeps the older half of
a full ring while moving the *newer* half to `inject` (`LeanIn/Model/Pool.lean:52,119-125`), so the
257th submission of `0..256` leaves the ring holding `0..127` and the new `256`, and `inject` holding
`128..255`; and `Pool.take`'s `takeFromRing` serves the ring before `inject` (`:81-86`), so the receipts
run `0..127` and then `256`, followed by `128..255`. The expected order is read from the model's rule rather than from the implementation's
output, and it is read as a sequence: those identities in another order fail here. Because `fifo` is
the first phase's own receipt boundary it carries no `300` and no `301` — the script stages those two
only in the second phase — so a client that staged either of them before the first batch was drained
would record it among these receipts and fail here, even though both identities are delivered later
and `staged` and `delivered` still hold all 263.

`lifo` is exactly `400,401,402` and `flush` is exactly `300,301,403`. `lifoCap` is 3 (`:54`) and
`Pool.take` polls the LIFO slot while the tick's allowance lasts, flushing a slot that is still
occupied once the allowance is spent (`:94-102`); so the three chained continuations are polled from
the slot, the pending `403` is flushed to `inject` when the allowance is exhausted, and the ring is
then served — `300`, `301` — before the flushed `403`. A fourth poll of the slot in place of that
flush fails here, and because `flush` is the second phase's own receipt boundary it stays separate
from the `fifo` receipts of the first phase.

`slotBefore` is exactly `[0:400,1:401,2:402,3:403]` — the scheduler's own slot observation taken at
the decision itself, before each of the three polls and before the flush, keyed by the poll count. It
is the record the scheduler produced at that instant, not a value the client retyped from the
expectation, so an implementation that never populated the slot would have to record `-` and fail
here; the first three entries are nonempty identities at poll counts `0`, `1` and `2`, and the fourth
is nonempty at count `3` immediately before the flush. That is what makes the allowance observable
rather than assumed: the populated slot the three polls read is the local `spawn` operation's own
effect, and an always-empty slot cannot produce this sequence.

`staged` and `delivered` are read out of their own named fields as multisets of identities and must
each be exactly the 263 staged identities, once each: an identity duplicated with another missing, an
unknown identity, or work left behind (`remaining` must be `0`) fails. `remaining` only corroborates
the receipts, and never stands in for them.

Those detectors are held to their own control inside the same invocation. The multiset detector
accepts the full 263-identity set and rejects a staged/completed set carrying one identity duplicated
and another missing. The one sequence detector accepts the modelled `fifo`, `lifo`, `flush` and
`slotBefore` orders and rejects four near misses — the pair either side of the capacity crossing
exchanged, a `lifo` that took `403` as a fourth poll in place of the flush, an always-empty slot
`slotBefore=[-,-,-,-]` that only a vacuous allowance test would accept, and a first-phase `fifo` whose
receipts carry `300` and `301`, which is what a client that staged them before the first batch was
drained would record. The phase detector accepts the ordered stream and rejects the same five events
with `stage:300` and `stage:301` recorded before `batch-drained`, so a run that staged the two
identities early fails on the phase order even after every token has arrived exactly once. Every near
miss is built from the expectation or the record syntax alone, never from the executable's receipts,
and a control that does not hold is a fixture defect reported separately from the `Then`: a detector
that accepted any near miss, or that rejected the modelled order, has not asserted this `Then`.

**Why.** The queue's promise is that a staged item is held until it is taken, and that the LIFO
allowance is a policy which can never strand work; local `spawn` is what makes that allowance
reachable, by placing the spawned continuation in the slot, while the worker's `wake` only un-parks a
worker and places no work. A ring that drops the half it cannot hold when it overflows, or an allowance that
never saw a populated slot or keeps polling past its cap and leaves the pending continuation behind,
still reports plausible receipts — while losing exactly the work the caller staged. The two phases
keep those receipts honest: a first batch that already carried `300` or `301`, or a `flush` reached
without a fresh tick after the drain, would still deliver all 263 identities while the boundary this
check names was never crossed. The `phase` stream binds that boundary to the client's own actions, so
a run that staged `300` and `301` before the drain cannot pass on a correct-looking batch and identity
set.

______________________________________________________________________

### SC21 — a chain that keeps the LIFO slot occupied is interrupted at the allowance, and the allowance is refreshed by the next decision that is not a slot serve

**Actor.** A client of the executor's own take, on the mode's own thread: one carrier
(`Sched.Executor.new Nat 256 1`), the driver's spelling standing in for worker `0`. The mode owns the loop —
it locally `spawn`s the chain's root, and after each take that returned a chain link it locally `spawn`s that
link's successor, so the slot is re-filled before the next decision. One marker is submitted to the ring
before the chain starts, because a flush has to have something of the ring's to serve. Nothing here writes a
ring, a slot or a counter: every value is read from a public operation, and each slot observation is the one
the take reported at its own decision.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC21`, which invokes
`lake exe controls --executor-lifo-turns`. No socket, no thread, no clock, no external service: the actor is
the executor's own public take on the invocation's thread.

**Given.** The mode's own identities: a chain of 12 links from 400, continued one successor per delivered
link, and the marker 300 submitted to the ring before the chain starts. The allowance is the pool's own
`lifoCap` — 3 (`LeanIn/Model/Pool.lean:63`) — read out of the record rather than stated by the check, and
read back by the check against the mode's stated value.

**When.** One invocation, one record. The mode takes until a take returns nothing, recording each decision's
`served` and `observed`, the item it delivered, the flushes, and the composition's own accounting:

`lifoturn|cap=<n>|links=<n>|served=[<slot|flushed|queue,…>]|observed=[<id|-,…>]|delivered=[<id,…>]|flushes=<n>|held=<n>|taken=<n>|pendingAfter=<n>|runUs=<n>`

`served`, `observed` and `delivered` are bracketed comma-separated lists, read with the same shape
`id_sequence_is` accepts. `observed` is the slot's occupant as each decision read it, `-` where it found the
slot empty; `delivered` is the item each decision served, in order; `flushes` counts the decisions that
cleared a spent slot; `held`, `taken` and `pendingAfter` are the composition's own numbers — work still held,
work taken, and the shared list's length. `runUs` is printed and never asserted: no relation here reads a
clock.

**Then.** There is exactly one `lifoturn|` record, and its fields are exactly `cap`, `links`, `served`,
`observed`, `delivered`, `flushes`, `held`, `taken`, `pendingAfter` and `runUs` in that order with nonempty
values, so every value is bound from one parsed invocation. With `cap` the record's own allowance and `links`
its own chain length the clause is four conjuncts, evaluated in this order and each on its own named fields:

- **the cap bites.** The `served` sequence contains exactly `cap` consecutive `slot` decisions followed by a
  `flushed`, repeating: every maximal run of consecutive `slot` decisions is `cap` long, each such run is
  immediately followed by a `flushed`, a `queue` never interrupts a run, and the sequence ends on a flush
  rather than on a run of polls. Every `flushed` decision reports, in `observed`, the occupant it cleared — a
  chain identity, never `-` (an empty slot is a `queue` decision, not a flush) and never the ring's marker,
  which lives in the ring and not in the slot.
- **the allowance is refreshed by any decision that was not a slot serve.** After a `flushed`, the next
  decision that finds the slot occupied is a `slot`, not a second clear of the same spent allowance. The
  slot's occupancy at each decision is the record's own `observed`, so the relation is read from two named
  fields rather than from a schedule the check assumes. This is the conjunct that tells the bounded schedule
  from both spellings production has on the current tree: the driver's, where the allowance is never
  refreshed inside the take and so the flush repeats, and the carrier's, where it is refreshed inside every
  take and so no flush ever happens.
- **the flush is a move, not a loss.** `delivered` is read as a multiset and must be exactly the chain's
  `links` links and the marker, each once — the link a flush cleared is delivered, by that decision or by the
  shared list's next one, so a flush that dropped it fails here. `flushes` must be the derived count below,
  and the accounting must be intact: `held + taken` equals the mode's `links + 1` submissions, `held` is 0
  and `pendingAfter` is 0, so nothing is left in the shared list either.
- **the flush serves the ring.** The marker submitted before the chain started is served at index `cap` — the
  first flush — and the decision that reads `flushed` there is the one that served it. Without this conjunct
  the clear could be a schedule that never serves the ring at all, which is the fairness property the
  allowance exists for (`docs/interface.md:139-143`).

**The expectation is derived, not typed.** Every shape the four conjuncts read comes from the model, driven
along the schedule the bound fixes — `Model.Pool.take`'s decision composed with `Model.Pool.tick` when the
decision was not the slot's (`LeanIn/Model/Multi.lean:451,496`), in the order
`Multi.takeStep_returns_if_present` names them (`:1193-1204`). For a chain of `links` links from `first`, a
marker `marker` in the ring, and an allowance `cap`:

| | derived |
|---|---|
| `served` | `slot` × `cap`, `flushed`, `queue`, then (`slot` × `cap`, `flushed`) repeated `flushes - 1` times |
| `flushes` | `⌈(links - cap) / (cap + 1)⌉`, one flush per `cap + 1` links of the chain past the first block |
| `observed` | the chain's links in order, with `-` at index `cap + 1` |
| `delivered` | the chain's links in order, with the marker at index `cap` |
| `held`, `taken`, `pendingAfter` | `0`, `links + 1`, `0` |

For this mode's identities — `cap` 3, `links` 12, `first` 400, `marker` 300 — that is
`served=[slot,slot,slot,flushed,queue,slot,slot,slot,flushed,slot,slot,slot,flushed]`,
`observed=[400,401,402,403,-,404,405,406,407,408,409,410,411]`,
`delivered=[400,401,402,300,403,404,405,406,407,408,409,410,411]`, `flushes=3`, `held=0`, `taken=13`,
`pendingAfter=0`. The sequence was computed by driving the model — `Model.Pool` through `Model.Multi`, over
the repository's own oleans — rather than written down here, and the check's expectation function carries the
same rule rather than these values: `served` and `observed` are built by the rule above, and `flushes` is
computed from the record's own `cap` and `links`. The derivation is a scratch program outside the repository,
so no scaffold for it is checked in; the fixture's own expectation function is the checked-in statement of
exactly what it computed.

The `queue` decision at index `cap + 1` is part of the model's composition rather than an artefact: the flush
clears the (cap+1)th link into the shared list and serves the ring, which holds the marker, so the link it
cleared is what the *next* decision takes — and because the chain's own step re-fills the slot only from a
delivered link, that decision finds the slot empty and reports `-` in `observed`.

**Why it is not vacuous.** Five affirmative controls are in the same invocation. The mode's stated allowance
and chain length are read out of the record and required to be the values the clause is stated for, so a run
with another allowance is the clause's own failure rather than a silent pass; the chain length is required to
exceed `2 * (cap + 1)`, so a run too short to have been interrupted twice cannot pass here; and `flushes` is
required to be at least 2, so "the bound held" is not the statement that nothing happened. `delivered` is a
multiset check with a count, so the flush arm cannot pass by dropping the item it cleared. And the four
conjuncts are exercised — before the invocation, on the record syntax and the expectation alone — against the
near misses they must reject: the **pre-fix driver spelling**, whose allowance is never refreshed inside the
take so the flush repeats; the **pre-fix carrier spelling**, which refreshes inside every take so the slot
serves the whole chain and no flush happens; a fourth slot poll in place of the flush; a flush reporting an
empty slot; a flush whose cleared link is missing from `delivered`; the marker served by a decision that is
not the flush's; and one flush more than the chain's length allows. Each of those shapes was itself derived
by driving the model with that schedule. A control that does not hold is a fixture defect reported as a setup
error, separately from the `Then`.

**Why.** `Executor.takeFor` refreshed the allowance inside every take, so `lifoPolls` returned to zero on
each decision and the spent-allowance arm could not run while a chain kept the slot occupied. The bound the
interface documents (`docs/interface.md:139-143`) is per carrier and cannot strand the slot's occupant; what
the refresh bought was the chain's locality. This scenario reads the restored schedule off one chain that
never yields: the cap interrupts it, the link the interrupt cleared is the shared list's next item rather
than a loss, the ring is served by the interrupt, and the allowance is refreshed by the decision that
followed — which is what a chain that yields sees instead of a demotion.

**Limits, stated.** (i) The derivation above holds for a chain length that is a whole number of `cap + 1`
blocks, which is what makes the chain end on a flush; a chain that stopped mid-block would end on a run of
polls, and the mode's 12 links at `cap` 3 are three such blocks. (ii) What is read is a sequence of
*decisions*, not a liveness property: nothing here proves that a task runs, and no ordering or priority
promise is added — `docs/interface.md:353-360` stands. Nothing is bounded in time either, and no clause reads
a clock; `runUs` is printed and never asserted. (iii) The mode drives the driver's spelling of the take; the
carrier's own consequence — a chain that holds the slot being interrupted on the carrier's path too — is
SC12's green and the take-path measurement's flush count, not this scenario's. (iv) The bound is a property of
a chain that holds the slot: a chain whose links are served from the ring or the shared list never reaches
this rule, and its shape is unchanged by it.

### SC22 — a step's deferred enqueue takes the route of the worker that fires it, and a chain across carriers completes

**Actor.** The public `controls` executable in a new mode, `lake exe controls --executor-route [--bound N]`,
playing two arms over one invocation, both of them the task layer's own `Async.await`/`Join` machinery rather
than a fixture-side stand-in.

*The route arm* keeps its two roles on two workers of one `Sched.Executor.newMetered Task.Item 256 2`. Worker
`1`'s shift is a dedicated thread of its own — `IO.asTask (Executor.workerLoop e (fun i it => it.fireWith i)) 1`
with `Task.Priority.dedicated`, the same thread shape `Runtime.startCarriers` uses — and its identity is the tid
`Executor.noteTid` records in the carrier counters' entry for it. Worker `0` has **no** loop of its own: the
invocation's thread stands in for it, which is the driver's own convention (`Runtime.blockOn` drives worker `0`
on the calling thread). The creator's step is the task layer's deferred registration — `Async.await` on a cell
with no value yet — built as `Item.ofIndexed (some token) (Runtime.fired token e creatorProg done 0)`, so the
`Ctx` it runs with has worker `0`'s routes; it is placed on worker `0`'s queue with `Executor.submitLocal` and
fired with `Item.fireWith 0`. The resolving step is an item whose program is `Join.resolve cell ()` followed by a
read of `Executor.snapshot`; it is delivered through the shared route (`Executor.pushInject`, the one route a
thread that is not a carrier reaches) and fired by **worker `1`'s carrier with index `1`**, so the fire which
defers comes from a peer thread relative to the creator.

*The completion arm* is one `Runtime.Executor.newMetered 256 2` with both carriers started through
`Runtime.startCarriers e 2` — the multi-carrier entry's own configuration — and the mode's own thread only
observing and waiting.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC22`, which invokes the executable synchronously
and parses its records. Nothing here calls a private function: every compared value is a named field of a record
the executable printed on stdout, and the two gates the arms wait on are cells the *composition* owns. Every
wait the mode makes is a **round count** bounded by `--bound`, never a clock, and the check reads that number
from the mode's own `sc22cfg|bound` line rather than typing it: a round is a locked read (`Join.value?`,
`Executor.observe`), an expiry yields `resolverRounds`/`completionRounds` at the bound and the clause's reading
fails, and the invocation's watchdog (300 s) stays only a hang bound. The bound is larger than the dispatch-only
modes' 20000 because these arms wait for a dedicated thread's *first shift* and for an item to be taken and run
on it, not for one wake: a bound's worth of rounds is ~12 ms on this box, against `runUs` rows of a few hundred
microseconds for an arm that does not expire.

**Given.** For the route arm: an executor whose worker `1` is a started carrier — its counter tid is read before
anything is pushed, and the check requires the record's `firerTid` to be that identity rather than the creator's
— and a cell no one has resolved. For the completion arm: both carriers started, one `Join` cell the mode's own
thread watches while the chain runs, and one link delivered through the shared route.

**When.** One invocation, two records, each arm's ordering enforced by the mode's own steps rather than by which
carrier wins a race:

1. **The route arm.** The creator's step registers a continuation on the cell and returns; worker `0` has no
   loop, so nothing takes from worker `0`'s pool while the arm runs. The resolving step is then pushed to the
   shared list, taken by worker `1`'s carrier, and fired with index `1`: it resolves the cell — which runs the
   registered continuation's enqueue *on that thread* — and then reads `Executor.snapshot` **before its own step
   returns**, so the pools are read at the arrival rather than after a race (worker `1` cannot take from its own
   queue while it is inside a step, and worker `0` has no loop to take with). The mode then takes from worker
   `0`'s pool and fires whatever it finds there, which is what turns "the item landed on the creator's pool" from
   an inference into a reading, and waits on the continuation's own cell for it to have run.
2. **The completion arm.** The creator's root is delivered through the shared route; it delivers its link the
   same way, and then **holds inside its own step** until that link has started, which is what keeps the link out
   of the creator's reach (a carrier inside a step cannot take from the shared list). The link holds until the
   creator's carrier is *parked*, read from the composition's own `parked` count — neither link is inside a park
   when the hold begins, so the first nonzero reading is the creator's — and then completes, which resolves the
   creator's cell and enqueues the creator's continuation wherever that resolution's route sends it. The mode
   waits on the completion cell by the same round count, and then stops and joins the carriers and reads the
   composition's own `held`.

**Then.** There is exactly one `route|` and one `crossing|` record per invocation, shaped exactly with nonempty
values, as

`route|creator|firer|p|creatorPoolBefore|creatorPoolAfter|firerPoolBefore|firerPoolAfter|pendingAfter|creatorTid|firerTid|continuationTid|continuationRuns|resolverRounds|bound|runUs`

`crossing|p|completed|creatorRuns|childRuns|continuationRuns|crossed|waiterParked|creatorTid|childTid|continuationTid|completionRounds|bound|heldAfterStop|runUs`

plus the mode's `sc22cfg|bound|p|creator|firer` line. With `bound` the mode's own printed round count, the
clauses are:

- **SC22-O1 — the deferred enqueue takes the firing worker's route.** The two roles are distinct workers
  (`creator = 0`, `firer = 1`, and `creatorTid ≠ firerTid`): the peer's identity is the carrier counters' own tid
  for the firing worker. Both pools are empty before the resolving step, and after it the item is in the *firing
  worker's* pool (`firerPoolAfter = 1`) and **not** in the creator's (`creatorPoolAfter = 0`) and **not** on the
  shared list (`pendingAfter = 0`) — so the clause tells the owner-made local route from both the captured-route
  spelling, which leaves the item in the creator's pool, and the shared route, which leaves it on the shared
  list. The firing worker's own thread ran it (`continuationTid = firerTid`, `continuationRuns = 1`), the
  creator's did not, and the resolve was observed inside the mode's own round count (`resolverRounds < bound`).
- **SC22-O2 — a chain across carriers completes.** `completed = 1` and every link ran exactly once
  (`creatorRuns = 1`, `childRuns = 1`, `continuationRuns = 1`); the crossing is observed, so "it completed on one
  carrier" cannot pass as "it completed" (`crossed = 1`, i.e. the link's carrier is not the creator's, both tids
  nonzero); the completion arrived at a wait that was parked (`waiterParked = 1`, the count the link read from
  the composition before it completed); it arrived inside the mode's own round count
  (`completionRounds < bound`), so a completion produced by the drain that follows is not this reading; and the
  drain left nothing held (`heldAfterStop = 0`). `continuationTid` names the thread the deferred continuation
  ran on — the *route* clause's subject, read in the `route|` record — and is bound by the check's shape so a
  record that lost it is rejected, but no conjunct here compares it: this clause is about the chain's completion.

`runUs` is printed and never asserted: a timing assertion is a flake with a schedule.

**Why it is not vacuous.** Seventeen affirmative controls are in the same invocation, run before the invocation's
own records are asserted, each built from the record syntax and the derived expectation alone and never from the
executable's receipts. O1's detector is exercised on the record the clause is stated for — the deferred item on
the firing worker's own pool, its thread running it — and on seven near misses it must reject: **the spelling the
tree implements today**, where the continuation holds the awaiting step's route and so lands in the creator's
pool with the creator running it; the rejected shared route, where the item goes to the shared list instead of a
worker's own pool; the same item read in both pools; an item that reached no pool and never ran; the
continuation run by a thread that is neither role; the two roles collapsed onto one worker; and a resolve that
hit the mode's own round count. O2's detector is exercised on the completed crossing and on eight near misses:
the chain that never completed with its continuation never run (the shape a lost wake leaves); a completion
whose continuation never ran, i.e. one read from a cell rather than from the work; a completed chain with its
link short; a completion on one carrier where a crossing was required; a completion that arrived at no parked
wait; a completion read after the mode's own round count expired; a link run twice; and a drain that left the
deferred item behind. The mode's own identities are read out of its records and required to be the ones the
clauses are stated for, so a run at another carrier count or another round count is the clause's own failure
rather than a silent pass; and O1's positive half is a *pool* reading, so "it went nowhere" and "it went to the
wrong pool" are told apart rather than both passing as "not the creator's pool". A control that does not hold is
a fixture defect reported as a setup error, separately from the `Then`.

**Why.** A step's re-enqueue route travels in the `Ctx` its closure holds, and `Async.spawn` builds its child's
context out of the parent's — so a child's later pushes would take the *parent's* route rather than the route of
the worker that fires the child. The third site is the `Join`-cell continuation: `Async.await` registers
`fun v => ctx.resume (Item.ofAction (k v))`, which closes over the *awaiting* step's route, and
`Join.resolve`/`resolveFirst` run their registered continuations **directly on whichever thread resolved the
cell**. A deferred item therefore lands in the creator's own queue while the push is made by a peer thread: the
push is not owner-made, and it is visible only because the executor's wake protocol records the push in the
shared cell and wakes every waiter so the owner is among them. The `route|` record reads that arrival from the
executor's own snapshot taken inside the resolving step, and the `crossing|` record reads what the wake buys: a
chain whose link was delivered through the shared route and whose continuation was deferred onto a parked
carrier completes, with the crossing observed from the carriers' own tids.

**Limits, stated.** (i) The route arm drives worker `0` on the invocation's thread and starts only worker `1`'s
loop, so the pools are quiescent and the arrival is a reading; the clause is about *where the deferred item
lands*, not about a live multi-carrier schedule, and the live schedule's reading is the completion arm's. (ii) The
crossing in the completion arm is *forced by construction* rather than observed as the scheduler's choice: the
creator holds inside its step so the link cannot be taken by it, and the link holds until the creator's carrier
is parked, so the completion necessarily arrives at a parked wait. Nothing here therefore measures how often a
crossing happens; it reads what one crossing does. (iii) `waiterParked` is the composition's own `parked` count
as the link read it, so a run whose creator was not parked when the completion arrived is the clause's own
failure rather than a silent pass. (iv) Nothing here is bounded in time and no conjunct reads a clock: the round
counts bound a wait so that a lost wake is a reading rather than a wedge, and `runUs` is printed and never
asserted. (v) The completion arm's `continuationTid` is not compared by O2 on purpose: the route's reading is
O1's, and this record's clause is about the chain's completion — a reader wanting both readings wants both
records.

### SC23 — composition: a parent machine awaits a child machine over a real socket

**Actor.** A Lean executable server (`./.lake/build/bin/defuncEcho 8390 parentT`): `amParentT`, an
`asyncMachine` state machine that awaits `amChunkT` — another compiled machine — twice on one accepted
connection, each call suspending the parent until the child's terminal `halt` fires the parent's own
continuation as the child's `onDone`. Both machines report thread ids as they run, and the harness reports its
own and a dedicated task's. The peer is a shell pipeline writing two chunks with pauses — deliberately not
ours. The child's continuation parameter is filled by the generator with the parent's continuation: a machine
awaiting a machine is a raw resume, and no cell is allocated for the call.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC23`, which builds `defuncEcho`, serves it on a
fixed loopback port, and exchanges two chunks with the served parent over `/dev/tcp`. Nothing here calls a
private function: the records asserted on are the wire's own byte stream with the read's own bound, and the
server's `sc23|` tid records on its stdout.

**When.** The client writes `AAAA` and, after a pause, `BBBB`. The served parent awaits the child for the
first chunk, then for the second, then sends both answers back together. The read runs under the fixture's own
5 s bound, whose firing is recorded as `bounded`, exactly SC20-O3's shape: the bound is an invocation bound
and a conjunct of the relation, never the relation itself.

**Then.** Four conjuncts, each its own detector, with the controls below read in the same invocation.

- **SC23-O1, completion.** `bounded == no`: the composed exchange completed — the parent's resend arrived
  before the bound. A composition whose child's `onDone` never resumes the parent produces a prefix and this
  bound.
- **SC23-O2, order.** The stream is exactly `AAAABBBBAAAABBBB`: the child's two echoes in order, then the
  parent's combined resend — the resend's *presence* being the child's `onDone` having resumed the parent
  with both answers.
- **SC23-O3, resumption thread.** Each call's `resumeTid` equals its `childStepTid`: the parent resumed on the
  child's own completion thread, which is what a raw resume is; a resume delivered through a cell and an item
  would land wherever the carrier was.
- **SC23-O4, one driver.** Every recorded tid — both `childStepTid`, both `resumeTid`, and the accept loop's —
  equals the harness's `mainTid`: in the single-carrier driver, the accept loop, the connection's effects and
  the resume are one thread, and a hop to another thread is a delivery, not a resume.

**Controls, in the same invocation.** (i) The bound detector reports `bounded=yes` on a real timeout: a
connection that stays open and silent, read under a 1 s bound, must exit 124, or the `bounded == no` reading
is an absence a broken detector could always report. (ii) The tid detector reads the harness's dedicated task
as a different thread from `mainTid`, so the equalities in O3 and O4 are readings rather than a detector that
cannot differ. (iii) The tid records are shape-checked before they are read: two `childStepTid`, two
`resumeTid`, and one each of `acceptTid`, `mainTid`, `dedicatedTid`, and a missing or repeated record is a
setup error, never a pass.

**Limits, stated.** A single-carrier harness cannot distinguish a cell-mediated resume from a raw one by
thread (a `Join` plus inject would read the same driver thread here), and the multi-carrier entry does not
serve this shape (the `runCarriers` serving defect recorded beside `LeanIn/Exe/Server.lean`), so O3/O4 read
resumption and driver-unity, not the absence of a cell: the no-cell fact is structural (the generator passes
the caller's continuation as the callee's last parameter, and the expansion names no cell) and is costed by
the M2 benchmark in `docs/asyncmachine-workplan.md`. The port is fixed (`8390`) inside the invocation's own
loopback; the readiness probe's connection is an ordinary parked read and changes no record. Nothing here
measures the call's cost; this scenario asserts order, completion, and resumption.

### SC24 — time as an effect: sleeps and deadline races at the harness clock's stated instants

**Actor.** A Lean executable server (`lake exe controls --runtime-machine-time`): two clauses, each a compiled
machine served under `Runtime.runVirtual` with the harness clock injected as the machine's clock, and each
awaited by the run through a `Join` cell the machine resolves on its close *submission* — so the run holds
until the machine's terminal step rather than its first suspension, with the socket's closure observed
separately by the client reading to EOF. Clause one is `amDelayed` (read, `sleepRaw` `d`,
answer, close); clause two is `amStall` (a `recvTimeoutRaw` race against the same instant). The client is
`Std.Async`'s, driven by `Async.block` on the mode's thread.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC24`, which invokes the public `controls`
executable. Both listeners are bound by the invocation (`Runtime.loopback 0`); no live clock is read on a
harness run — an instant is a number, and the virtual driver advances to the earliest pending timer one idle
round at a time.

**When.** Clause one: the client sends `tick tock`; the machine must not answer until the harness clock reaches
`delay` (30). Clause two: the client connects and never sends; the deadline must win at `stall` (30), with
nothing written.

**Then.** Two records, read by their named fields.

- **SC24-O1 (`dl|`).** `at == delay` — the answer arrived at the harness clock's own stated instant, not
  before it and not after (the virtual driver stops when the run's cell resolves, so `at` is the instant the
  machine's close fired). `got == "tick tock"` — the answer carried the request. `bounded == no` — the
  client's live-time bound never fired, so the answer was not a bound-truncated reading. `pendingAfter == 0`
  and `inFlightAfter == 0` — the clause left no timer and no step behind.
- **SC24-O2 (`st|`).** `at == stall`, `clientGot` empty, `pendingAfter == 0`, `inFlightAfter == 0`,
  `carrierThreads == 1` (the single server-side thread recorded at entry): the deadline ended the connection
  at its stated instant with nothing written and nothing left in flight. O2's empty reading is controlled
  by O1's non-empty `got` in the same invocation — the same client-read detector reported bytes in one clause
  and none in the other — so the absence is a reading rather than a detector that cannot differ.

**Limits, stated.** `at` is the harness clock's own reading, not a wall-clock measurement: the virtual driver
advances exactly to the next pending instant and stops when the run completes, so the relation `at == stated
instant` is about the machine's scheduling against its injected clock, never about real elapsed time. The
client's live-time bound is an invocation bound, recorded (`bounded`) and asserted only as `no`. The mode's
clock wrapper is the harness's own composition — arming a timer from the loop's thread also nudges the parked
driver through the executor's inject, the load-bearing wake `Io.liveSchedule` documents for the live clock;
without it the arm strands.

### SC25 — spawn: a machine scheduled as an executor item, joined through its completion cell

**Actor.** A Lean executable server (`lake exe defuncEcho <port> spawn`): each accepted connection is served
by `amSpawn`, which reads one request byte (the join-order selector), spawns two `amChunkOf` children through
`Runtime.sharedPush` — the first carrying `BBB`, the second `AAA`, always in that order — joins the two cells
in the order the selector names (`0`: first spawned then second; `1`: the reverse), echoes the joined bytes,
and closes. Each child is a single `onDone` step whose boot runs as an executor item, and its completion
resolves the cell the parent awaits.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC25`, on loopback. One client — `ec_client`,
which connects, optionally sends, and reads to EOF under a bound — serves both the assertion and the control.

**When.** Two connections on the same server: one sends `0`, one sends `1`.

**Then.** The answers are `BBBAAA` and `AAABBB`, both completed unbounded.

- **SC25-O1, completion and through-reach.** Neither read hit the client's bound: the boot items reached the
  executor through the app's inject and their resolutions resumed the parked parent. The detector is the
  client's own bound, and its affirmative control in the same invocation is that same client against a `cps`
  echo with an empty request and a 1 s bound, which must exit 124. This asserts **reach**, not the wake:
  the parent enqueues both boots while it is running, and the driver drains queued work before parking, so a
  push that enqueued without waking would still be taken here. The wake a parked driver needs is
  `Runtime.sharedPush`'s — the inject SC2 exercises (an injected completion waking a waiting `blockOn`), with
  SC18's wake from a non-carrier thread as its companion. The spawn adds no wake path: it calls the same
  inject every other push does.
- **SC25-O2, join order governs.** The two clauses spawn identical children (BBB first) and differ only in
  the join order, and they answer `BBBAAA` and `AAABBB`. A collector that returned completions in completion
  order would give one order in both clauses; a value-sorting collector cannot satisfy both. So the bytes
  bind the join order to the handle that owns each payload.
- **SC25-O3, typed handles.** The handles are `RawCell ByteArray` field values carried across the parent's
  suspension to the joins; the generated spawner's payload type comes from the child's own `onDone` domain.

**Limits, stated.** The scenario observes order, completion and through-reach; it does not observe which
carrier ran a boot, and neither clause controls the completion order itself — that is why two swapped joins
are used rather than a staged completion. The children carry a connection they do not use (the spawn surface
takes one so the handle type stays the child's own). The port is fixed inside the invocation's loopback.

### SC26 — select: first-wins over two cells, with registration order as the tie rule

**Actor.** A Lean executable server (`lake exe defuncEcho <port> select`): each accepted connection is served
by `amSelect`, which reads one request byte and selects over two cells it creates itself, answering with the
winning index paired with that cell's own payload. On `A` the second cell (payload `one`) resolves before the
select and the first (`zero`) after it; on `B` both resolve before the select.

**Boundary.** `nix develop -c bash tests/executor-contract.sh SC26`, on loopback; the same `ec_client`
detector as SC25, with the same `cps`/1 s-bound control in the same invocation.

**When.** Two connections on the select server carrying `A` and `B`, each read to its end under a bound.

**Then.** The answers are `A1one` and `B0zero`, both completed unbounded.

- **SC26-O1, first-resolved wins, with its value.** `A1one`: the cell resolved before the select resumed it
  with index 1 and with that cell's payload, even though the other cell registered first; the loser's later
  resolution produced no second resume (the answer carries one pair and the connection ends).
- **SC26-O2, registration order is the tie rule.** `B0zero`: with both cells already resolved, the first
  registered cell wins, with its own payload, as `Task.select` documents.
- **SC26-O3, completion.** Both reads completed unbounded: neither select nor the loser's parked waiter held
  the connection open.

**Controls, in the same invocation.** (i) The two clauses report different winners and payloads (`1one`
then `0zero`), so the winner field is a reading rather than a constant. (ii) The bound detector is the same
client under a 1 s bound against a silent `cps` connection, which must exit 124.

**Limits, stated.** The loser's parked waiter remains registered until its cell resolves and then no-ops; the
scenario observes that no second resume reaches the machine, not the waiter's storage. The select's value type
is the cells' own, and the tie rule is the registration order of the two awaits in `selectRaw`.
