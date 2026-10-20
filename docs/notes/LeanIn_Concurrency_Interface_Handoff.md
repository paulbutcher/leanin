# LeanIn: evolve the asyncMachine interface for general concurrency

Date: 2026-10-20.

Reviewed LeanIn revision: `4b93289`. Lean toolchain: `v4.35.0-rc3`.

Status: design handoff, not an implemented or compiled API. Syntax examples under “Proposed surface” are illustrative.

## Recommendation

Keep the sequential-looking authoring model and compilation into explicit states. Evolve the public interface toward typed computations with guaranteed terminal outcomes, explicit resource policy, owned child lifetimes, and extensible effects.

Treat generated machine layouts, completion callbacks, and executor injection routes as implementation details. They can remain available to runtime authors and proof/debugging tools without becoming ordinary application parameters.

This is an interface project, separate from current HTTP performance work. Preserve the ability to compile direct calls without allocating a completion cell per call.

## Current strengths and limits

The current interface supports compiled calls, spawn/join, selection, timers, and a generic first carried parameter. Explicit states and suspension points are useful for runtime inspection and transition-system reasoning.

The restrictions are not inherent to defunctionalisation. They come from the current effect classifier, field typing, calling convention, and lifecycle policies.

The largest issue is completion: authors manually supply and invoke `onDone`. An EOF or transport failure can end a generated path without resolving a spawned child's handle. The guide acknowledges that joining such a child can then wait forever. This must be resolved before calling the interface generally compositional.

## 1. Make completion part of the machine contract

Give each machine an explicit result type. Have source `return`, failure propagation, and cancellation compile to terminal outcomes. The runtime/compiler owns delivery of that outcome; authors should not have to remember a callback.

Conceptual outcome shape:

```lean
inductive Exit (ε α : Type) where
  | success (value : α)
  | failure (error : ε)
  | cancelled
```

This is a suggested semantic shape, not a demand to allocate this particular wrapper at every step. Decide whether errors are explicit in the computation type or fixed by the public API, and distinguish cancellation from ordinary application errors.

Required laws:

- Every terminating execution delivers exactly one terminal outcome.
- Completion, failure, and cancellation cannot deliver two outcomes.
- A waiter on a terminated child observes its outcome; it does not remain parked because a callback was omitted.
- An execution may genuinely diverge or remain blocked. Do not claim that all spawned computations terminate.

Callbacks may remain the compiled calling convention. Separate “call this computation” from “spawn an independently scheduled child”: only the latter inherently needs a child handle. The result-bearing interface must not force a promise allocation at every call.

Define what happens to `halt`: either remove it from result-bearing public code or give it a specified terminal meaning. A silent halt that abandons a joiner is not an acceptable successful return.

## 2. Separate primitive outcomes from resource policy

The current read form delivers bytes on success and closes on EOF. Binding versus discarding a write's result also selects different control-flow handling. These are useful server conventions but surprising general-purpose semantics.

Prefer these distinctions:

| Layer | Responsibility |
| --- | --- |
| Primitive read/write | Report bytes, EOF, or error with documented transport cleanup ownership |
| Error-propagation notation | Decide whether failure exits the surrounding computation |
| Resource scope | Release what this computation owns on every exit path |
| Server convenience combinator | Apply close-on-EOF or close-on-error policy where appropriate |

Discarding a result must have an explicit, documented meaning. Merely adding a binder should not silently select a different resource policy.

EOF is not universally a request to close a whole connection. A bidirectional relay may propagate a half-close and continue traffic in the other direction. Preserve correct cleanup ownership for broken transports while exposing enough information for application protocols.

The socket compiler must also use the operands actually written by the author. At the reviewed revision, some socket effects are classified without retaining their connection operand, then lowered against the machine's carried connection. Ordinary read lowering also substitutes a fixed size. Test operations on two distinct connections and nondefault read sizes; do not silently accept syntax whose arguments will be ignored.

## 3. Define a small public concurrency vocabulary

| Concept | Meaning |
| --- | --- |
| Call/await | Sequential composition with a typed result |
| Spawn | Start separately progressing work; specify whether it is scheduled or may start inline |
| Join handle | Observe that child's terminal outcome |
| Scope | Own and account for child lifetimes |
| Cancel | Request termination with specified observation and cleanup rules |
| Select/race | Wait for alternatives with an explicit policy for losers |

Do not expose the ability to resolve a child's result through an ordinary join handle. Keep promise/resolver capabilities separate from handles that observe completion. `RawCell` can remain a runtime substrate.

Recommend scoped child ownership as the normal application pattern, with deliberate detachment as a separate operation. Specify whether a scope waits for children, cancels them, propagates failure, or aggregates outcomes. These are design choices, not properties supplied automatically by a block of syntax.

Distinguish selecting existing handles, whose losers may continue, from racing scoped operations, whose losing branches may be cancelled. Support heterogeneous alternatives through an explicit sum/result type when needed. Avoid a requirement that unrelated operations have the same result type merely because the current two-cell selector does.

Hide `push` from ordinary application signatures. Carry an execution capability/context through the runtime, or bind it at an explicit runtime boundary. Runtime authors can still use routes directly.

## 4. Make effects extensible through a typed contract

Another library should be able to introduce a channel, semaphore, database request, or custom event source without editing the compiler's `classify` function.

Specify an effect contract covering:

- Result type and errors.
- Immediate versus suspended completion.
- Which execution owner/thread may resume the computation.
- Exactly-once delivery and late-completion handling.
- Cancellation and retirement of registrations.

The interface can remain completion-driven; Rust-style polling is not required. A registered compiler hook, typed adapter, or awaitable abstraction could all be candidates. Choose one that preserves resolved operand identity and allows efficient lowering.

Distinguish an ordinary synchronous IO leaf from a genuinely asynchronous registration. Wrapping blocking IO in an async type does not make it nonblocking; retain an explicit blocking-pool route.

## 5. Improve typing without making the whole language a prerequisite

Use elaborated bindings and resolved local identities as the destination for field typing and liveness analysis. Avoid inferring a value's type by recognising the function to which it is later passed.

Explicit ascriptions are an acceptable staged restriction. Reject unsupported types and constructs clearly. Do not change application datatypes merely to satisfy compiler heuristics, and do not silently fall back to placeholder types.

Document the semantics of loops and rebinding. The current use of shadowing `let` to thread values through `recurse` is a distinct convention, not ordinary lexical `let` behaviour. Prefer conventional mutable locals or explicit next-state parameters when extending the public language.

Preserve ordinary Lean helper functions. Specify the supported boundary for dependent values or types crossing suspension rather than claiming every dependent program is immediately supported.

## 6. Specify scheduling independently of source syntax

Awaiting an already-ready operation is not necessarily a yield. Define immediate-completion behaviour, reentrancy, cooperative budgets, and the treatment of long synchronous work.

Preserve three distinct layers:

| Layer | Purpose |
| --- | --- |
| Source program | Operations, dependencies, and synchronization |
| Generated transition system | Control states, live values, suspension and terminal transitions |
| Execution plan | Carrier placement, queueing, wakeups, and cooperative budgeting |

This supports single-carrier execution today without hard-coding that placement into every application API. Claims about parallel execution still need appropriate thread-safety boundaries.

Expose generated states and trace hooks for reasoning and debugging, while keeping physical layout out of application contracts. Typechecking generated Lean is useful but does not establish preservation of source control flow or effects; track that proof obligation separately.

## Proposed surface

Illustrative only; the names and type spelling require design and compilation checks:

```lean
proc fetchPair (a b : Conn) : LeanIn.Async ByteArray := do
  let x ← read a
  let y ← read b
  return x ++ y
```

The source has an ordinary result, actual operation operands, and no completion callback or injection function. The backend may still emit explicit constructors and a continuation-taking runner.

Do not require this exact syntax before settling the lifecycle semantics. A shorter name alone does not make the current callback protocol compositional.

## Acceptance workloads

1. **Socket relay:** two independently identified connections, partial reads/writes, half-close, error, cancellation, and cleanup.
2. **Bounded producer/consumer pipeline:** channel backpressure, child failure, cancellation, and scope exit.
3. **Request with timeout:** both winner orders, immediate completion, cancellation of a loser where specified, and harmless late completion.

Each workload should compose reusable helpers without new cases in `classify` or datatype workarounds. Test every terminal path and observe outcomes through public handles, including EOF and errors before the source's normal return. Check that bound/discarded results obey the documented policy.

Follow repository `AGENTS.md` and existing executable-contract idioms. Measure performance separately: a correctness requirement should not be excused by a faster incomplete lifecycle, and a result-bearing surface should not be assumed to allocate a cell per call.

## Suggested implementation order

1. Define terminal outcomes and compiler-owned completion; close the dangling-join paths.
2. Preserve actual operation operands and separate primitive results from application cleanup policy.
3. Introduce join handles, child scopes, and cancellation contracts.
4. Introduce typed extensibility and move field analysis toward elaborated bindings.
5. Add the shorter authoring name as a compatibility alias, then migrate examples.

Do not rename generated namespaces, proof artifacts, and user syntax in one unreviewable change. Preserve `asyncMachine` during migration and avoid conflating a naming-only patch with lifecycle changes.

## Naming recommendation and collision check

Recommend `proc` as the short authoring declaration, retaining `asyncMachine` as the implementation/backend description and a compatibility alias. It suggests a suspendable procedure or process without exposing the generated state-machine representation. Document that declaring a procedure does not spawn it: calling, spawning, and joining remain separate operations.

`async def` is the strongest alternative for familiarity. It describes the programming model clearly and resembles an ordinary function declaration, but the word `async` already appears as methods in `Std.Async`. That is a naming overlap, not proof of a command-parser conflict.

| Candidate | Assessment |
| --- | --- |
| `proc` | Recommended: short, general, and no matching declaration/command found in the scanned pinned Lean source. Clarify that it is not an OS process. |
| `async def` | Clear function-oriented alternative. No matching command syntax found, but `Std.Async` already has `async` methods. Test tokenisation and imports before adopting. |
| `fiber` | No matching declaration/command found, but better describes a running lightweight task than a reusable computation declaration. |
| `coro` | No matching declaration/command found; concise but emphasizes coroutines more than general concurrency. |
| `task` | Avoid as the principal name: Lean already has `Task`, and LeanIn also has task abstractions. The conceptual ambiguity is greater than the saving. |

Verification scope: checked a local checkout of Lean `v4.35.0-rc3`, commit `470d5ce1400764999581fd26d5d72b00d990b0f4`. Searched `.lean` sources under `src/Init`, `src/Std`, and `src/Lean` for candidate syntax literals, and searched declarations in Init/Std/parser sources. Existing `async` definitions were found in `Std/Async/Basic.lean` and `Std/Async/ContextAsync.lean`; the standard `Task` namespace is also present. No candidate keyword syntax was found for the short names above. This is a source scan, not an executed parser-compatibility test, and does not cover Mathlib, downstream plugins, or future Lean releases.

Use the `LeanIn` namespace for public types and implementation declarations. Evaluate scoped command syntax (for example enabled by `open scoped LeanIn`) to limit grammar exposure, and test its actual tokenizer/parser behaviour. A namespace alone does not make quoted syntax tokens private or guarantee grammar isolation.

Before landing a rename:

1. Compile minimal import combinations with Lean core, `Std`, and LeanIn.
2. Check ordinary identifiers and qualified method uses, especially existing `.async` calls if choosing an async-prefixed command.
3. Exercise ordinary declaration modifiers, documentation comments, namespaces, and diagnostics on the chosen surface.
4. Keep old examples working through an alias, without duplicating the compiler.
5. Retain qualified runtime types and a documented escape spelling if another library adds overlapping syntax.

No name can be guaranteed collision-free against arbitrary future imports. The claim for `proc` is limited to the scanned pinned distribution.

## References

- [Reviewed LeanIn revision](https://github.com/scidonia/leanin/tree/4b93289).
- [Current authoring guide](https://github.com/scidonia/leanin/blob/4b93289/docs/asyncmachine-guide.md).
- [Compiler and effect classifier](https://github.com/scidonia/leanin/blob/4b93289/LeanIn/Async.lean).
- [Machine scenarios](https://github.com/scidonia/leanin/blob/4b93289/LeanIn/Test/Machines.lean).
- [Raw completion cells](https://github.com/scidonia/leanin/blob/4b93289/LeanIn/Runtime/VM.lean).
