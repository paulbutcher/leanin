# The raw completion registry: ownership, threading and marking

Scope: the C table that parks one Lean continuation per `(connection, op)` for the compiled-machine I/O path
(`c/netuv.c`, `LeanIn/Runtime/Io.lean`). This is a design argument tied to the code, not a machine-checked proof;
the executable checks are listed at the end.

## State and operations

State is `S = ⟨slots : (conn, op) ⇀ Obj, count : Nat, lock⟩`, where `Obj` is a Lean closure. Operations:

| operation | transition |
| --- | --- |
| `register(conn, op, k)` | consumes `k`; if a slot was occupied its old `Obj` is decremented; the slot now holds `k`; `count` rises only when the slot was empty. Refuses (and decrements `k`) when the index is out of range or the registry is uninitialised. |
| `take(conn, op)` | clears the slot, decrements `count`, and transfers the `Obj` to the caller. Returns `none` if empty. |
| `withdraw(conn, op)` | `take` and drop: the continuation is never invoked. |
| `drain()` | at loop teardown: decrements every remaining `Obj`, clears all slots, sets `count = 0`. |

## Invariants

- **I1 — accounting.** `count` equals the number of occupied slots. Checked by the self-test after each transition.
- **I2 — single ownership.** Every occupied slot holds exactly one reference that no other owner holds; `register`
  consumes its argument, and no path both stores and decrements the same reference (`old == k` is legal when the
  caller's second use carries its own increment).
- **I3 — exactly once.** `take` clears the slot before the caller invokes the closure, so a second completion or a
  late event finds `none`; a timeout and a completion race resolve to one `take`.
- **I4 — no stranded operation.** A refused registration is reported to Lean, which raises; it is not a silent
  drop. (This was a real gap in the first version: out-of-range and pre-loop registrations were silently dropped.)
- **I5 — lock discipline.** Map operations are serialised by `g_raw_lock`. The closure is invoked *after* `take`,
  outside the lock, so a continuation that registers another operation cannot deadlock.
- **I6 — no Lean call in the shim.** The shim only stores, clears and returns references; dispatch and invocation
  happen in Lean. This keeps the "callbacks never run on foreign threads" rule intact.
- **I7 — teardown.** `drain` runs in `destroy_loop`, so a stopped loop does not leak outstanding registrations.

## The compiler contract

The shim relies on `@[extern]` arguments being **owned**: the callee consumes them, and the compiler inserts an
increment when a source value is used again. This was checked against the pinned toolchain rather than assumed —
compiling a two-use caller emits:

```c
lean_inc_ref(v_k_12_);
v___x_16_ = np_raw_register(v___x_14_, v___x_15_, v_k_12_);
...
v___x_19_ = np_raw_register(v___x_14_, v___x_18_, v_k_12_);
```

and a single-use caller emits no increment. Consequences: `register` must consume exactly one reference (store or
decrement), and reusing one closure for two slots is legal only because the second use is incremented.

## Why publication matters for performance

Lean classifies an object as multi-threaded when it is stored into a reference that is itself multi-threaded or
**persistent** (`ref_maybe_mt`, `lean_st_ref_put`/`lean_st_ref_swap`), and `lean_mark_mt` traverses closure
environments and ref contents. A module-level `initialize` is persistent, so the old `Std.Mutex (HashMap …)` made
every parked continuation — and everything it captured, including the machine state and its byte arrays —
multi-threaded. The runtime then takes the atomic reference-count path and `lean_is_exclusive` is false, so array
updates copy. The C table is not a Lean reference, so this classification never reaches the stored continuation;
the objects stay single-threaded and exclusive updates stay available.

This is an ownership boundary, not a bypass: the reference is still owned exactly once (I2), the reference count is
maintained correctly, and no Lean object is mutated through a stale or aliased pointer. The control that motivated
it measured the same update at 22 984 ns/iter through a published cell against 277 ns/iter through a private one.

## What the evidence covers, and what it assumes

Checked by execution:

- `lake exe controls --raw-registry` — register/take, no double take, replace, withdraw, count returns to zero;
- `tests/executor-contract.sh SC19/20/23/24/27` and `tests/bridge-contract.sh BT1–3`, including the exact stall
  instant and the error/EOF paths;
- a 30 s mixed stress run at C=8 (keep-alive, pipelined, churn), zero errors;
- `NETUV_RAW_CHECK=1` adds the scalar-closure check and traces refusals.

Assumed, not proved:

- the owned-argument FFI ABI (evidenced by generated C, above);
- the `Option` representation used when returning a taken closure (`lean_alloc_ctor(1,1,0)` / `(0,0,0)`);
- thread-safety of Lean's allocator and `uv_mutex` for the calls made here;
- reference counting as the sole reclamation mechanism (no moving collector), so a pointer held in C is stable.

Not covered by the argument: the rest of the shim (connection state, submission and event queues), which is a
larger trusted base with its own invariants. The registry theory says nothing about those.
