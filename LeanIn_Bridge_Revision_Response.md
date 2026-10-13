# Response to the bridge revision review (8 October)

Your review was accurate, and §4 was the finding that mattered. What follows is disposition and
evidence, so you can check the work rather than take it.

## Disposition

| § | Finding | Disposition |
|---|---|---|
| 1 | Separate an isolated effect from a call interval | **Partly taken** — `Runs` now states that for a call with internal stages the pair is the *composition*, not one instant. Splitting `Effect` from `Call` is the programme. |
| 1 | Confirm `Tid` is a native carrier, not a green task | **Already done** — documented as a native thread, carrier or waker. |
| 2 | Execution composition for the actual `do` block | **Not taken** — programme. The rename below is the honest interim. |
| 2 | Rename `calls_compose` | **Taken** — it is now `lock_wait_unlock_postcondition`. |
| 3 | Restrict the bridge to admissible representations | **Not taken** — programme; the local condition is the standing position, argued below. |
| 3 | Do not equate two distinct Lean values with two distinct native allocations | **Already the standing position** — the global form was tried, rejected as an over-assumption, replaced by a local pairwise condition. |
| 4 | Specify notification by exact membership changes | **Taken** — the substantive change of this round. |
| 4 | Decide the notification-strength contract separately | **Decided** — no release is promised; see below. |
| 5 | Keep clock monotonicity separate from timing guarantees | **Retained as-is** — the sample is carried by *every* non-clock axiom, not only the demonstrated call. |
| 6 | Preserve model validity and tracked state | **Not taken** — programme; your own remedy (an abstraction relation) is that same work. |
| 7 | Expand the audit to the claimed runtime guarantee | **Taken, with one item impossible** — there is no runtime-facing scheduler theorem yet to print. |
| 7 | `#print axioms` does not display hypotheses | **Taken, and made concrete** — see the third line of output below. |

## §4 — exact notification effects

You were right, and right for the reason that makes it serious. Two length inequalities permit
`[Alice, Bob] → [Carol, Dave]`: the length is unchanged and at most one entry was lost, so both clauses
hold and a wakeup that *replaced* the waiter set was admissible — while the model's `erase` has no such
behaviour. The axioms were weaker than the model they exist to carry: true of the machine, insufficient
to bridge it. Your additional point that "every original member is gone" plus "does not grow" *also*
admitted the replacement was the decisive part, and I had missed it in the previous round.

Both now state an exact effect. `notifyOne`: the list is untouched, or one named element is gone.
`notifyAll`: every waiter present is gone, and none appears.

Two consequences are now theorems — `notifyOne_no_additions` and `notifyAll_no_additions` — neither
derivable from the count. And because a claim about a strengthening needs the detector to have found the
defect while it was present, the superseded form is kept as a control: `counted_notify_admits_replacement`
accepts `[0, 1] → [2, 3]`, `exact_notify_rejects_replacement` refuses it. The pair is the mechanism; the
single acceptance on its own would prove nothing.

## §7 — the audit, widened, and its limit

Your dependency list is printed, with actual output rather than intent:

```
lock_wait_unlock_postcondition      depends on axioms: [lock_spec, unlock_spec, wait_spec]
readings_monotone_across_a_call     depends on axioms: [clock_spec, lock_spec]
distinct_mutexes_are_distinct_locks does not depend on any axioms
notifyOne_no_additions              depends on axioms: [propext, notifyOne_spec]
notifyAll_no_additions              depends on axioms: [notifyAll_spec]
```

The third line is your observation made concrete: **axiom-free while assuming `NonAliasing`**. `#print axioms` reports dependencies and never hypotheses, so an empty list means nothing was assumed *as an
axiom* — never that nothing was assumed. That is written beside the block, together with your point that
nine named axioms are not the whole native trusted base: the compiler and runtime sit outside them.

## A decision, recorded rather than assumed

**No release is promised by either notification contract.** "One is released if one is eligible" is a
progression assumption, and the base bridge excludes progress — the same stance as no fairness. The exact
effect on the condvar is stated; whether any waiter ever *runs* is a later rung. This is why the contract
is stated at removal strength and the stronger obligation is deliberately declined rather than left
ambiguous.

## What you could not see, and it is not your error

You reviewed from `Bridge.lean` alone, and two of your checks were already satisfied. `Tid` is documented
as a native carrier, never a green task. And `clock_spec` already carries the sample on every non-clock
axiom, not only on the demonstrated call — so §5's concern about preservation "for every permitted
non-clock event" is met at the axiom level, with the single-call theorem standing as the demonstration
rather than as the whole claim.

Your §3 caveat about equating two distinct Lean values with two distinct native allocations is also
already the standing position: the global form was written, rejected as stronger than the allocator
guarantees, and replaced.

Separately, and relevant to what you are about to see: every model-side defect found so far came from an
executable reachability probe over the model, not from reading it. Three successive versions of one
predicate reported success for witnesses that were not the claim, and a waiter-invariant violation was
found within four actions. Reading has not found that class of defect once.

## What I did not take, and why it is not a patch

§1's `Effect` against `Call`, §2's execution composition, §3's `ValidRep` with lifetimes and address
reuse, §6's per-primitive frame conditions, and §7's runtime-facing theorem. Each is the programme both
handoffs describe, and §6's own remedy — an abstraction relation separating untracked implementation
effects from tracked corruption — is that same work. Taking it replaces the milestone's approach rather
than correcting it, so it is a scope decision, not a repair. If you disagree about any one of these being
separable from the programme, say which: §4 is evidence that a finding can look like a bound and be a
fidelity failure, and I would rather hear it from you than find it later.

## Where I want pushback

On §3 specifically. You note that a `NonAliasing` hypothesis on a later theorem does not restrict the
operation axioms themselves. True as stated. The position taken is that no *conclusion* can be drawn
without it — the guard is the theorem that requires the hypothesis, and a collapsing map cannot justify
a distinct-object claim — so the axioms stay unqualified and the condition is enforced where it is
consumed. If you think that leaves a soundness or fidelity gap the guard does not close, that is the
argument I want.

And on §6, a narrower question: whether per-primitive frame conditions are separable from the abstraction
relation after all. "A primitive cannot corrupt an unrelated tracked object while still qualifying as a
valid isolated effect" is stated as an acceptance check and reads to me like a conjunct that could be
added now, leaving only the untracked-effects half to the relation. If you agree, it is a small change
and I will take it next; if the two are genuinely one object, say so and I will leave both to the
programme.
