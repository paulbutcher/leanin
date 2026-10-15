# The defunctionalization approach (`async!` / the `VM`)

Status: **experiment, uncommitted** — validated on the echo, not yet on `serveConn`.

## Goal

A Tokio-style concurrency engine for Lean whose steady-state performance is within ~1.5× of Node. The HTTP
server is the vehicle, not the point: the point is the general engine a client writes async code against.

## The problem, measured

The merged single-carrier driver (the serving carrier pumps the I/O loop itself) removed the cross-thread
handoff, so the I/O model and scheduler are no longer the gap. What remains is **per-request heap churn in the
async machinery**, not the I/O. Profiling (`callgrind`) of `serveConn`:

- ~47% of instructions are memory management (alloc / free / refcount / GC mark), ~9% closure application.
- The actual HTTP parse+write is **under 2%**.

Two kinds of allocation make up that churn:

1. **The engine's completion delivery** — every suspension (`recv`/`send`/`await`) allocates a `Join` cell, a
   waiter, an `Item`, and an `Item.ofDeferred` closure, and pays the inject + carrier-fire round trip.
2. **The client's own CPS closures** — every `←` in a client's `do` block is a `bind` whose continuation is a
   freshly allocated closure. This is the larger, *general* cost: you cannot hand-optimize it per loop.

## The approach: defunctionalization

Make a suspended computation **data** instead of a closure, and resume it **directly** instead of through the
cell+item apparatus. Client code still *reads* like async (`do` with `←`); under it, the continuation is a
machine state the engine resumes in place.

Three pieces, in increasing order of polish:

### 1. Raw delivery (engine-side) — done, validated

`Io.recvRaw` / `Io.sendRaw` / `Io.registerRaw`: a completion resumes its continuation *on the loop thread*,
with **no** `Join` cell, `Item`, inject, or carrier fire. This is the resume mechanism everything else uses.

*Measurement* (plain TCP echo, CPS echo vs raw echo, `callgrind`): **67.4k → 29.7k instructions/request
(−56%)**; C=32 throughput +27%.

### 2. The `VM` monad (client-side) — done, validated

`LeanIn/Runtime/VM.lean`: a free machine over the socket effects with a `Monad` instance, so a client writes
**ordinary `do`** and it elaborates into machine data; the incremental interpreter (`VM.runK`) resumes each
effect by raw delivery. This is the general mechanism — no hand-defunctionalizing each loop.

*Measurement* (echo written as `do` in `VM`, `callgrind`): **30.9k instructions/request (−54% vs CPS)**, within
~6% of the hand-written raw echo. C=32 throughput +22% over CPS.

Lean obstacles hit and cleared: free-monad `bind` won't compile as `partial` (Lean can't prove `VM β` nonempty
for the fallback), and a `bind`-constructor GADT hits a universe error on the indexed type. Working form:
parameterized `VM` + `partial` bind + a default `.empty` constructor for the `Inhabited` the fallback needs.

### 3. The `async!` elaborator — the plan

The `VM` still keeps *function* continuations inside its nodes and pays a quadratic free-monad `bind`. The
`async!` elaborator compiles a `do` block to a **flat state machine** — one inductive constructor per
suspension point, carrying the live variables, plus a `step` function the driver matches on — resumed through
the same raw delivery. That removes the remaining overhead and is the ergonomic interface. Suspensions are
marked `await (e)` so the macro can split the block syntactically; liveness (which variables cross each
suspension) is the part that needs a scenario gate.

## Where this lands against Node

The delivery VM is **necessary but not sufficient** for 1.5×. Rough per-request decomposition of `serveConn`
(from the echo experiment + timeout spikes): delivery machinery ~16%, `withTimeout` race ~20%, **HTTP layer
(H1 machine + response encode) ~50%**, socket+misc ~14%. So:

- delivery VM → ~2.0× Node; + a cheap `recvTimeout` → **~1.5×**, the HTTP+socket floor.
- Beating 1.5× comfortably needs the H1 layer reimplemented to allocate far less (Node's llhttp is C,
  zero-copy; ours is a persistent functional machine). That is a separate, larger project.

## Honesty notes

- Echo is a minimal loop (2 suspensions, no H1/handler); `serveConn` carries irreducible H1+handler on top, so
  its *percentage* win is smaller — the per-suspension machinery is identical.
- The VM's interpreter runs the client on the loop thread (right for the single-carrier driver; multi-carrier
  needs thought). Raw delivery parks the loop per op; a batching VM would keep switches low.
- All of this is experiment-quality (`VM.lean`, the raw path in `Io.lean`, `DefuncEcho.lean`); gate holds 22/22.
