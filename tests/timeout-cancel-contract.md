# Timeout cancellation — behaviour checks

`Runtime.withTimeout` is a race between a computation and a clock, and the first writer wins. What the
computation does after its own deadline has won is the other half of that statement: a `<none>` result is only
a timeout if the work it abandoned stops. The check here drives that at the public `controls` executable and
reads the events the executable's own client recorded, so nothing below asserts an internal call, a pending
timer or an elapsed time.

```sh
nix develop -c bash tests/timeout-cancel-contract.sh TC1
```

The fixture is `tests/timeout-cancel-contract.sh`. Its `When` is one invocation of
`lake exe controls --runtime-time-loser`, a harness-only mode that prints one `timeoutLoser|` record and runs
nothing else: it neither reads a live clock nor performs a real sleep. It shares no path with the live
`--runtime-time` diagnostic that SC8 reads, whose `time|`, `timebase|` and `timectl|` records keep their own
existing live-clock behaviour. The instants this clause reads come from `Runtime.HarnessClock` — fresh
in-memory clocks whose only mechanism is a mutex over a list — so the clause reads numbers it states rather
than wall time, and reaches no socket, network service or live clock.

A failure before the scenario's own assertion — the executable did not run, the library did not build, the
record is absent, repeated or malformed, or the detector's own affirmative control does not hold — is reported
as a setup error with exit 2, separately from a scenario assertion, which exits 1. A bounded wait is never the
scenario's result.

## TC1 — a timed-out computation never resumes afterwards

**Actor.** An executable client of `Runtime.withTimeout`: the `controls` executable, running one fresh
single-carrier executor against one fresh `HarnessClock`.

**Boundary.** One invocation of `nix develop -c bash tests/timeout-cancel-contract.sh TC1`, which runs
`lake exe controls --runtime-time-loser` and reads its single `timeoutLoser|` record. The computation and the
deadline are the production operations; the events are the client's own annotations.

**Given.** One fresh event list and one `recordAfter` action that appends `after` to it. The detector's
affirmative control is that action executed for real: on a separate harness clock, a virtual sleep runs
`recordAfter`, and the same `List.contains "after"` reads the list while the marker is present, reporting
`afterDetectedWhenPresent=true`; the list is then cleared for the losing run. In that run the executor is fresh
and single-carrier and the clock is fresh at instant `0`: a child computation appends `start` to the same list,
sleeps to virtual instant `30`, and takes the same `recordAfter` action after waking. The deadline is instant
`10`. The root, after the timeout returns, sleeps to instant `50`, so `10 < 30 < 50` strictly, and the child's
sleep is reached before the root's.

**When.** The client invokes `Runtime.withTimeout` at virtual instant `0` with the deadline of `10` and that
child as its computation, waits for the `Option` result, sleeps until instant `50`, and reads the harness
clock.

**Then.** The record is exactly `outcome`, `start`, `after`, `advanced` and `afterDetectedWhenPresent`, bound
to this race's result, to this child's own recorder and to this harness clock's instant. `outcome` is `none` —
the deadline won, so the result is the timeout's and not a value. `start` is `true`: the same recorder that
must not see a post-sleep effect did see the child begin, which is what makes `after=false` an observation
about the child rather than about a recorder that never ran. `after` is `false`: the same `List.contains` that
observed the marker in the affirmative control found nothing recorded after the child's sleep. `advanced` is at
least `30`, so the clock reached the instant the child wakes at, and the absence is read after the child could
have resumed rather than before it ever could. `afterDetectedWhenPresent` is `true`: the affirmative control's
actual reading, required before the absence may be accepted, because a `false` there is a fixture or control
setup failure rather than this `Then`.

Nothing here asserts elapsed time, a pending timer count, or any internal call: the loser's disposal is
observed only through whether it acted.

**Why.** `Runtime.withTimeout` returns `none` when the deadline wins, and a caller reads that as "the work
stopped". If the abandoned computation continues past the deadline — running its later steps, then its
sleep's wake — the `none` means only that the caller stopped waiting, and work it believes abandoned is still
writing, still spending a carrier, and still reaching whatever the computation touches. The two outcomes are
indistinguishable from the caller's side, which is why the child's own recorder, and a root that outlives the
child's wake, are the observation.

The detector reading those five conditions is exercised inside the same invocation: it accepts a well-formed
record and rejects eight near misses — a loser that recorded `after`, a `start` the recorder did not see, a
computation that won instead of timing out, an instant one short of the wake, a repeated `after` field, a
record missing `advanced`, a false affirmative control, and a record missing `afterDetectedWhenPresent`. Every
near miss is built from the record syntax and the expectation, never from the executable's output, and a
control that does not hold is a fixture defect rather than this `Then`. The synthetic near misses supplement
the executable's own affirmative control; they do not stand in for its actual reading of a marker that
`recordAfter` really appended.
