# LeanIn bridge review: handoff for the next iteration

Reviewed: `Bridge(1).lean` and `World(2).lean`\
Date: 8 October 2026\
Status: source-level review; this iteration was not compiled.

## Assessment

This iteration fixes substantive defects in the representation and notification contracts. The next milestone should resolve the meaning of execution and connect a concrete scheduler code path to model traces. Additional endpoint axioms alone will not establish that connection.

## Keep these improvements

- **Representation inside execution.** Keep `Runs r t op w res w'`. This closes the earlier bug where the same execution witness could be reinterpreted through arbitrary constant representations.
- **Exact notification membership effects.** Keep the requirement that notification removes existing waiters without introducing new ones. The `notifyOne` contract now selects one entry when the list is nonempty. Selection does not assert that the selected thread eventually runs.
- **Waiter uniqueness.** Keep `World.WaitersNodup` and its preservation theorem. The `wait` precondition prevents duplicate enrolment on the same condvar.
- **Honest theorem scope.** Keep `lock_wait_unlock_postcondition` as a conditional endpoint theorem. Its name reflects what it currently proves.

## Priority 1: separate primitive effects from call executions

### Problem

The documentation assigns two meanings to `Runs`:

1. An isolated operation effect, with environment transitions represented separately.
1. For `wait`, a composition spanning release, enrolment, suspension, wake and reacquisition.

These require different semantic objects. A complete wait interval can contain environment actions and clock ticks. Its endpoints therefore need not satisfy `SameClock`.

If the intended composition omits interference, define how its stages connect through the surrounding execution. Documentation alone does not provide that relation.

### Suggested design

Introduce two relations, with names chosen to make their roles explicit:

- **`Event`**: one abstract effect, its result, and the fields it changes or preserves.
- **`CallExec`**: a native call represented by a trace containing its own stages and intervening environment events.

These names are architectural suggestions, not checked Lean declarations. An equivalent small-step design is acceptable.

Use `Atomic` only if the relation specifies an indivisible abstract transition. A native API call is not automatically one such transition; `wait` explicitly has multiple stages.

### Clock treatment

For an isolated `tryLock` effect, preserving `clock` and `lastSample` is appropriate: the operation itself neither advances abstract time nor samples the clock.

For the whole call interval, permit ticks and other actors' clock reads. Do not equate preserving the clock in an effect with the call taking zero time.

A failed `tryLock` is an observable result with a stuttering effect on the relevant lock state. It should not disappear from the execution vocabulary merely because it fails to acquire.

For call intervals, establish monotonic sample evolution through the trace instead of requiring equality across the entire interval.

## Priority 2: connect executions to model traces

### Problem

`wait_cycle_reachable` proves that a suitable model path exists. It does not establish that a particular native execution witness follows that path.

Likewise, `lock_wait_unlock_postcondition` combines three supplied `Runs` hypotheses. It does not derive those hypotheses from the semantics of a Lean `do` block.

### Required work

Define execution composition for the fragment of `BaseIO` used by the scheduler, including pure results and bind. State the runtime-to-model correspondence under the execution's representation and valid object context.

For a returning wait call, require a corresponding trace with:

- release and enrolment by the calling native thread;
- that thread's de-enrolment through notification or a spurious wake;
- reacquisition by that same thread before return;
- permitted environment transitions between these stages.

This is a conditional safety contract. It should not assume every blocked call eventually returns.

An uninterpreted execution relation also needs an explicit adequacy assumption or justification connecting actual native histories to its witnesses. Otherwise the contracts can all hold when the relation has no witnesses. Model-level examples do not resolve that issue.

## Priority 3: add frames to isolated effects

### Problem

The present lock contract constrains one owner and the clock. It permits arbitrary changes to unrelated locks and condvars, so unrelated scheduler invariants cannot generally be transported across it.

### Required work

Give each isolated event a frame over modeled state. For example, acquisition should update the represented lock while preserving other lock entries, condvars and clock state.

For call intervals, account for environment changes through the trace rather than imposing the primitive event's frame on the whole interval.

Keep representation validity separate from the frame. Including `r` in `Runs` fixes witness reuse, but does not establish that a chosen representation faithfully identifies the live runtime objects. Local non-aliasing hypotheses remain useful; allocation freshness and lifetime obligations must be supplied where needed.

## Commentary corrections

1. **Failed tryLock.** Its post-state non-ownership follows from the existing precondition and ownership preservation. Keeping the conjunct is convenient, but calling both conjuncts independently load-bearing is inaccurate.
1. **Fairness.** Replace “fairness is inexpressible” with “the model assumes no fairness and does not track pending lock requests.” Fairness conditions can be stated over enabled actions and infinite traces without a request queue.
1. **Waiter bookkeeping.** Some comments still describe duplicate enrolment as permitted or its exclusion as an open question. Update them to match the new precondition and preservation theorem. The model still allows parked actors to perform actions, so the invariant does not establish a full native-thread lifecycle.
1. **Notification alignment.** The model's `notifyOne` action can currently name an absent thread even when other waiters exist, producing a no-op. Either document this as a deliberate over-approximation or restrict selection to an enrolled waiter when the list is nonempty.
1. **Editorial cleanup.** Remove the repeated `notifyOne_no_additions` sentence and reconcile the “eight native operations” wording with the nine listed contracts.

## Acceptance criteria

The next iteration should:

- Give each execution relation one precise meaning.
- Represent a returning wait with a trace linking its stages to the same caller.
- Admit ticks and environment actions during blocking calls.
- Preserve unrelated modeled state across isolated primitive effects.
- Establish execution composition for one concrete Lean scheduler path.
- State explicitly the assumptions connecting native execution, representation validity and the model.
- Audit the resulting scheduler theorem with `#print axioms`, distinguishing runtime assumptions from model lemmas.

Start with one narrow path—such as lock, predicate check, wait and unlock—and complete its refinement before expanding the bridge. This will identify the assumptions the implementation proof actually needs.
