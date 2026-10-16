# `leanin`

A concurrency runtime and work-stealing scheduler for **Lean 4**, built so that the properties that matter are
machine-checked and the steady-state cost of async code is **data, not closures**.

The engine is general; the vehicle is an HTTP/1.1 server. On one box, in one run, 5 s per point, keep-alive with
a per-request handler (`bench/threeway.sh`):

| server | C=1 req/s | C=8 | C=32 |
|---|---|---|---|
| Node 22 | 45 380 | 139 857 | 101 042 |
| **leanin** | **29 932** | **42 241** | **37 705** |
| shipped `Std.Http.Server` | 2 166 | 3 363 | 2 687 |

**~14× the Lean HTTP server that ships with the toolchain**, and within 1.5× of Node at one connection. What we
are worse at — and there is a list — is in [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) §4, next to the
instrument's own ±30 % noise.

Status: **M2 closed, M3 under way** ([`PLAN.md`](docs/PLAN.md) §0, [`docs/decisions.md`](docs/decisions.md)). The
pure model is implemented and machine-checked (`LeanIn/Model/`, `LeanIn/Theory/World.lean`) with an executable
probe for its vacuity; `LeanIn/Theory/Bridge.lean` states the nine primitive contracts about the native
operations, each with a control and three with native trace scenarios under `tests/`; and the runtime serves
real connections on carriers of our own, which is what the table above measures.

## Where the design comes from

Liberal borrowing, named so that each claim is checkable rather than remembered:

- **Tokio** — the scheduler architecture, taken component by component from the Rust source. The reference copy
  is `Vendor/tokio/`, and [`docs/tokio-map.md`](docs/tokio-map.md) anchors every borrowing to a line in it: the
  multi-thread work-stealing flavour (per-worker local queue, shared inject queue, stealing), the LIFO slot, the
  current-thread flavour, the blocking pool, `defer`, `block_in_place`. One thing that document exists to
  correct: Tokio's queue is **not** a Chase–Lev deque — Tokio replaced crossbeam's with one adapted from the Go
  runtime, because dynamic growth needs epoch-based reclamation and reclamation costs two atomic RMWs on the hot
  path.
- **Node** — the I/O completion model. Our socket layer is a libuv loop of our own (`c/netuv.c`), so what a
  completion *is*, and where it resumes, has Node's shape.
- **Conor McBride** — the framing that makes the compilation below the natural target rather than a trick:
  *one-hole contexts*, the derivative of a regular type. Suspend a computation and what is left is a value with a
  hole where its answer belongs. That context **is** the machine state, and resuming is filling the hole.

## The state machine async — the important part

Client code reads like async — `do`, with `←` for a suspension — and it is **compiled**, not threaded through
closures.

`asyncMachine` (`LeanIn/Async.lean`) lowers a `do` block to a **flat state machine**: one constructor per
suspension point, carrying exactly the variables live across it (a liveness analysis decides which); a `step`
function the driver matches on; pure code inlined into the current state; and `if`, `while`, `for`, `break` and
`continue` lowered to transitions between states. Suspensions are marked `await`. Parameters are either constant
**step parameters** (the connection, the clock, the handler) or **threaded fields** (the H1 machine — state 0
carries it and `recurse` passes its current value back, which is how keep-alive state survives across requests).

A suspension allocates no `Join` cell, `Item`, inject or carrier fire. A completion **resumes its continuation
on the loop thread** — raw delivery — so resuming is a direct call rather than a wakeup round trip.

Why this is the important part is a measurement, not a preference. Profiling the serving path: **~47 % of
instructions are memory management** (allocation, free, refcount, GC mark) and ~9 % closure application, while
the HTTP parse and the response write together are **under 2 %**. The churn is the continuations themselves —
every `←` in a `do` block is a `bind` allocating a fresh closure, which cannot be hand-optimised per loop, only
defunctionalised:

| echo path | instructions/request | against CPS |
|---|---|---|
| CPS closures | 67 400 | — |
| raw delivery — a completion resumes in place | 29 700 | −56 % |
| the same echo written as ordinary `do` in `VM` | 30 900 | −54 %, within ~6 % of the hand-written raw echo |

Details, including the two Lean obstacles this ran into, are in [`docs/async-vm.md`](docs/async-vm.md).

## Install

The toolchain is named in **two places that must agree**:

| File | For | Toolchain |
|---|---|---|
| `lean-toolchain` | `elan` users | `leanprover/lean4:v4.35.0-rc3` |
| `flake.nix` | `nix` users | `lean4`, nixpkgs' `lean4` derivation at the `v4.35.0-rc3` tag |

The nix path builds that release from nixpkgs' own derivation rather than installing through `elan`, because
`elan` resolves `lean-toolchain` by downloading from the network, which an offline run may not do. nixpkgs
tracks `nixos-unstable` with no revision written in the flake: `flake.lock` records the revision actually
resolved, and `nix flake update` advances it.

```sh
nix develop -c lake build          # the library, the theory, and every harness below
```

4.35 rather than 4.34 is deliberate: `Std.WP`, the weakest-precondition framework the proof strategy leans on,
does not exist before 4.35.

One gotcha, because it looks like a code failure when it happens: the flake's `lean4` is an `overrideAttrs` of
nixpkgs' derivation, which no binary cache serves, so a store that lacks it compiles Lean from source — an hour
or more. Until the store has it, the same commands can run through the toolchain `lean-toolchain` names, which
`elan` provides at the same version; say which of the two ran.

`lake build` also prints the `#print axioms` audit from `LeanIn/Theory/Bridge.lean`, reporting what the model's
theorems rest on — currently only Lean's built-in `propext` and `Quot.sound`.

## Run

```sh
nix develop -c lake exe controls        # runtime controls: the primitive bridge, executor scenarios, HTTP
nix develop -c lake exe dynamics        # the model probe: is each contract's hypothesis reachable?
nix develop -c lake exe server          # the HTTP server on our runtime, port 8080
nix develop -c lake exe stdServer       # the same response via the shipped Std.Http.Server, port 8090
nix develop -c lake exe h1bench         # the head-parse microbenchmark
nix develop -c lake exe spike           # measure Lean's own scheduler (the harness behind docs/evidence.md)
nix develop -c lake exe defuncEcho      # the same echo: CPS closures against the compiled state machine

nix develop -c bash tests/executor-contract.sh SC1    # one scenario (SC1..SC22)
nix develop -c bash tests/bridge-contract.sh BT1      # one native trace scenario (BT1..BT3)

nix fmt                                 # treefmt over nix, shell, markdown and TOML
```

`nix fmt` runs treefmt: `nixfmt`, `deadnix` and `statix` on Nix, `shfmt` and `shellcheck` on shell, `mdformat`
on Markdown and `taplo` on TOML. Lean sources are the one file type it does not cover — neither treefmt-nix nor
nixpkgs ships a Lean formatter.

The shell runs `lake` and `lean` under `nice -n 19` by default, so elaborating `Std` yields to anything
interactive; `LEANIN_LEAN_NICE=0 nix develop` opts out.

Scenarios name an actor, an external boundary and an observable outcome, and live with their executable checks
in `tests/*.md` and the adjacent shell fixture. `tests/ModelOracle.lean` computes the pure-model side of the
executor scenarios independently.

## Benchmark

`bench/threeway.sh` runs every arm on this box inside one invocation, in the same mode — a per-request handler,
`bench/load.mjs` in keep-alive, `5 s` per point:

```sh
nix develop -c bash bench/threeway.sh          # levels 1 8 32
nix develop -c bash bench/threeway.sh 1 4 16   # chosen levels
```

The table at the top of this file is that driver's settled output. Read the ratios, not the absolute figures:
this instrument's run-to-run spread is ±30 % ([`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) §4.7), and a run
taken on a loaded box reads depressed — an earlier four-way of this shape was recorded at load average 4.8–6.0
and §4 carries the settled re-run beside it.

`bench/load.mjs` is a keep-alive client that sends, awaits the full response, and sends again;
`bench/node-server.mjs` is the Node arm, the same hello response shape.

## Documentation

| Document | Contents |
|---|---|
| [`PLAN.md`](docs/PLAN.md) | The plan, the roadmap, and the status |
| [`docs/decisions.md`](docs/decisions.md) | D0–D22, all closed, each with its evidence — and the limits each entry leaves open |
| [`docs/interface.md`](docs/interface.md) | The fixed interface: one spec, two implementations |
| [`docs/tokio-workplan.md`](docs/tokio-workplan.md) | The nine deliverables of the current milestone, with the evidence each requires |
| [`docs/proof-strategy.md`](docs/proof-strategy.md) | Property ladder, three-layer architecture, trusted base, the hard parts |
| [`docs/primitive-theory.md`](docs/primitive-theory.md) | What the externs guarantee: axioms, discharge, control tests |
| [`docs/tokio-map.md`](docs/tokio-map.md) | What we are taking from Tokio, component by component, with line anchors |
| [`docs/async-vm.md`](docs/async-vm.md) | The defunctionalization approach: raw delivery, `VM`, `asyncMachine` |
| [`docs/lean-scheduler.md`](docs/lean-scheduler.md) | The scheduler Lean actually uses today, read out of the runtime source |
| [`docs/lean-concurrency-today.md`](docs/lean-concurrency-today.md) | What Lean 4.35 already gives you, and the measured gaps |
| [`docs/reading-list.md`](docs/reading-list.md) | Annotated primary sources for proving scheduler facts, with verification status |
| [`docs/evidence.md`](docs/evidence.md) | Every measured and read-first-hand fact, with commands and anchors |
| [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) | Measured performance, its instruments, and the shapes where we are worse |

## Reference material

`Vendor/tokio/` is a read-only copy of the Tokio source, kept so that "this algorithm came from Tokio" is
checkable line by line. It is outside the build and carries Tokio's own licence.
