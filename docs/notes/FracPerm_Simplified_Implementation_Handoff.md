# Simplified fractional permissions for concurrent readers: implementation handoff

Date: 10 October 2026

## 1. Decision and objective

Build a second, smaller interface alongside the existing `Scidonia.FracPerm` implementation. Keep fractional permission reasoning, but make permission splitting and recovery consequences of structured concurrency rather than operations performed by clients.

Use two sealed computation types: a read-only `Reader α` and an exclusive-state `Program α`. A program enters a read phase, runs a tree of concurrent readers, joins every branch, and then resumes exclusive writes. Clients see no fractions, permission IDs, acquisition, release, ledger, or final ledger-closing proof.

The initial implementation supports one internally created protected object per execution, with a fixed collection of certified datatype operations. Begin with a numeric array. Add the counter with numeric log only after the array implementation works.

This is a design proposal. The schematic signatures below are not checked Lean code. Do not report model-level proofs as proofs of the current compiler or runtime.

## 2. Starting point

The supplied `FracPerm_Handoff.md` describes repository `Scidonia/lean`, branch `master`, commits `ed0c9a8`, `fc37899`, and `a6c2945`, with Lean `4.35.0-rc3` through Nix. It reports a core/Std-only implementation with:

- `Ledger.lean`: explicit outstanding fractional permissions.
- `Hoare.lean`: sealed Hoare computations and read tokens.
- `InPlace.lean`: optional exclusivity assertions.
- `Counter.lean`: a second object instance.
- Compile-time examples and a compiled in-place harness.

These are starting-point facts from that handoff, not a fresh repository audit. The implementer must inspect the actual checkout and its `AGENTS.md` before changing code. Preserve the pinned toolchain unless a concrete requirement demands a change.

The existing accounting does not prevent a read from returning the underlying state array or one of its mutable-in-place descendants. Such a result can remain live after its permission is returned. Lean's pure semantics remain safe through copying, but the intended ownership/performance property is lost.

## 3. Proposed public surface

Use a dedicated namespace, provisionally `Scidonia.FracPerm.Structured`, and specialize the first API to a numeric array. Generalize only when the second datatype supplies a concrete reason.

```lean
-- Schematic API, not compilable declarations.
Reader α
Program α

Reader.pure       : α → Reader α
Reader.bind       : Reader α → (α → Reader β) → Reader β
Reader.get        : Nat → Reader (Option UInt64)
Reader.size       : Reader Nat
Reader.parallel   : Reader α → Reader β → Reader (α × β)

Program.pure      : α → Program α
Program.bind      : Program α → (α → Program β) → Program β
Program.readPhase : Reader α → Program α
Program.set       : Nat → UInt64 → Program Bool

runFresh          : Init → Program α → IO α
```

`Init` describes scalar initialization, for example a size and scalar fill value. It does not contain an externally supplied protected array. Invalid sizes or indices have explicit behaviour; returning `false` for an out-of-bounds `set` is one simple option.

Derive ordinary `do` notation through `pure` and `bind` instances once their implementation is sound. The two computation types make the read/write restriction visible without indexed-monad syntax or routine arithmetic goals.

An illustrative use:

```text
runFresh (size = 1024, fill = 0):
    set 0 17
    (a, b) ← readPhase:
        parallel (get 0) (get 1)
    set 1 23
    return (a, b)
```

`Reader` has no write operation. `Program` has no detached spawn. `Reader.parallel` really schedules concurrent work in the concurrent backend; it is not merely a sequential pair combinator.

## 4. Fractions belong in the semantics

Associate every active read branch with a positive share of the same protected object. The root read phase has share 1. A binary fork gives each child half its parent's share. A join restores the parent share only after both branches terminate.

The proof judgment can be `ReaderSafe object q reader`; the public type need not mention `q`. Prove that each accepted reader is safe for every positive share at most 1. At `parallel`, instantiate its children at `q/2`.

```text
read:     preserves q, provided q > 0
fork:     q → q/2 + q/2
join:     q/2 + q/2 → q, after both children stop
write:    requires exclusive authority 1
```

This avoids arbitrary rational choices while retaining fractional reasoning. Dyadic shares suffice for nested binary splitting. The model can retain `Rat` for compatibility with existing arithmetic lemmas; there need be no executable share value.

Program descriptions may be duplicated. They are recipes, not ownership capabilities. Authority is introduced only by the sealed executor against its internally created object. A second `runFresh` executes against a separate object; it cannot obtain a second share of the first object's state.

The operational model must distinguish object/session identities, even if the one-object public API needs no explicit identity index.

## 5. Sealing and safe observations

Do not keep the open `FracObject` extension point in this API. Use fixed internal implementations of `get`, `size`, and `set`.

Keep raw state out of all client-facing values: constructors, runners, read handles, program results, and callback arguments. Audit autogenerated recursors and eliminators as well as named projections. The original handoff's private capability technique is a candidate to reuse, subject to checking the actual code.

Pure client continuations may compute arbitrary results from detached observations. There is no need to ban every function-valued result: a closure capturing a returned numeric value is harmless. The obligation is that it cannot capture the protected array, because no public operation makes that array available.

Do not expose callbacks of type `Array UInt64 → α`, including under a scope. Such a callback can return or capture the array. Do not expose an unrestricted operation constructor accepting arbitrary state-to-result functions.

Initially omit `liftIO`, public task handles, arbitrary asynchronous callbacks, and raw-state import/export. This keeps protected child tasks under the executor's control. These restrictions are about authority, not general limitations on ordinary pure Lean computation around observations.

## 6. Runtime execution and joining

The executor owns the state during a write phase. During a read phase it distributes read references to scheduled tasks. Read primitives observe this stable state; no write executes until the complete reader subtree has joined.

Waiting for a task result and eliminating all references held by task machinery are distinct concerns. Ensure the task closures, environments, and internal result wrappers do not retain protected state across the next write. Inspect compiled code and test the boundary rather than assuming that a join operation automatically restores runtime exclusivity.

Nested forks must join transitively. A parent cannot finish while a protected descendant remains active. Cancellation requests are not termination evidence.

For the first backend, normal completion joins both branches before resuming. If one branch fails, the executor still waits for the sibling to stop before leaving the phase. It may propagate the error and abort the session rather than resume writing. Do not reclaim shares on timeout while a task remains active. A nonterminating branch may therefore block completion; that is a liveness limitation, not permission recovery.

Cancellation is optional initially. If introduced, use cooperative cancellation followed by joining. Specify failure and cancellation separately from successful execution.

## 7. The small theory to prove

Keep functional correctness and ownership reasoning separate. Optional Hoare triples can specify array contents and return values on top of this API.

Define a small operational model containing a protected heap, object identity, active reader tree, and ownership/share invariant. For the first datatype, the protected footprint is the array storage; scalar payload representation need not be owned by that footprint.

Prove:

1. **Primitive observations:** `get` and `size` leave protected state unchanged and their results contain no protected locations.
2. **Reader composition:** sequencing and pure continuations preserve the no-protected-reference property of results and accessible client environments, under an appropriate semantic relation.
3. **Fraction conservation:** the sum of shares assigned to active leaves equals the authority allocated to their subtree; do not double-count internal tree nodes.
4. **Exclusion:** no write transition is enabled while any protected reader remains active.
5. **Join:** completing a subtree restores its authority only when all descendants have stopped and its result contains no protected aliases.
6. **Write preservation:** certified write primitives preserve the protected ownership invariant when executed exclusively.
7. **Whole-program safety:** composition preserves these properties from construction through session completion.

Model higher-order continuations honestly. If the proof models only first-order command trees, say so; that does not establish a theorem for arbitrary Lean continuations. A semantic relation for client values/functions or a precisely stated abstraction-boundary assumption is needed. Avoid introducing a large reflective language just to disguise this obligation.

Pure equality in Lean cannot state physical non-aliasing. Heap-model proofs must be tied to the sealed primitive implementations through explicit operational specifications or a checked translation. Document any remaining representation/compiler assumptions.

## 8. Ownership is not guaranteed by internal allocation alone

Internal construction removes caller-provided aliases, but compiler sharing and persistent constants can still defeat physical uniqueness. The existing handoff reports both literal-array sharing and common-subexpression sharing.

Distinguish three deliverables:

| Claim | Evidence |
| --- | --- |
| Read/write protocol and fraction conservation | Proofs over the structured execution semantics |
| No escaping protected aliases in that semantics | Primitive ownership specs plus composition theorem |
| Actual compiled in-place updates | Runtime assertions and compiled-code harness; stronger correspondence remains future work |

Concurrent sharing may also affect runtime representation and reference-count handling. Do not assume that the state becomes physically exclusive immediately after tasks have returned; verify it with the pinned runtime.

Use fixed-capacity element replacement as the first in-place benchmark. Array growth can allocate even without sharing. The performance objective is eliminating sharing-induced copies at certified updates, not claiming that every write allocates nothing.

## 9. Implementation sequence

### A. Audit and isolate

Read repository instructions and current modules. Add a separate namespace and preserve the original ledger API and its tests. Record the precise constructor/runner sealing strategy.

### B. Sequential core

Implement fresh initialization, the two monads, safe scalar reads, fixed-capacity writes, and a sequential interpretation of `parallel` for reference testing. This backend is not sufficient to satisfy the concurrency requirement.

### C. Concurrent backend

Implement real fork/join behind `Reader.parallel`. Add nested forks and explicit sibling handling on failure. Keep task handles internal. Inspect lifetime of protected references at the join boundary.

### D. Model and proofs

Prove the structured permission theorem and primitive no-leak properties. State the theorem's exact coverage of continuations, task execution, heap representation, and compiler assumptions. Reuse existing arithmetic lemmas where helpful; do not migrate the ledger wholesale.

### E. Compiled validation and second datatype

Check exclusivity before writes following concurrent reads. Add the counter/log datatype through the same sealed boundary, with operation-specific footprint checks. Only then decide whether shared infrastructure is worth factoring out.

## 10. Required acceptance evidence

| Case | Expected outcome |
| --- | --- |
| Write, two overlapping readers, join, write | Correct results; no write overlaps readers; compiled exclusivity checked |
| Nested parallel readers | All descendants joined before next write |
| Attempted write inside `Reader` | Rejected by the public API |
| Attempted raw-array extraction or forged runner | Rejected through all audited public routes |
| Reader returns a closure over a scalar observation | Accepted; closure does not retain protected storage |
| Reader failure while sibling is running | No subsequent write until sibling has stopped; error semantics recorded |
| Reuse one program description in two fresh sessions | Independent objects and results |
| Literal/CSE/shared-array controls in the existing harness | Continue to expose actual sharing; no inflated uniqueness claims |

Use controlled internal test barriers to demonstrate actual reader overlap and join ordering without adding public `liftIO`. Validate failure ordering with an internal backend fault-injection mechanism. Functional equality alone does not demonstrate concurrency or exclusivity.

Run the repository's required build and relevant existing tests. Add meaningful protocol, sealing, and compiled ownership regressions. Do not claim acceptance until the concurrent backend and post-join in-place checks have been exercised.

## 11. Migration and exclusions

Translate the common pattern `acquire → read-only body → release` into `readPhase`. Translate structured independent read bodies into nested `Reader.parallel`. Keep existing functional contracts as optional specifications of the new programs.

Do not automatically migrate programs whose tokens escape, whose readers detach, or whose read results expose mutable-in-place descendants. They require a stronger interface or a deliberate change in behaviour.

Defer detached readers, multiple protected objects per session, public custom instances, writes during a shared read phase, generic datatype descriptions, and compiler verification. Levitation can later generate certified layouts and operations; it is unnecessary to implement this fixed-family design.

## 12. Completion report

Return the implemented public API, one concurrent-read example, the precise proved theorem statements, their assumptions, build/test results, and compiled ownership findings. Identify any observed post-join sharing and resolve it or narrow the performance claim explicitly.

The proposed simplification is concrete: **two ordinary monads, sealed scalar observations, internal fractional reasoning, and structured fork/join instead of a client-managed ledger**.
