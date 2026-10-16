<p align="center">
  <img src="docs/assets/LeanIn.png" alt="leanin" width="720">
</p>

# `LeanIn`

LeanIn is a concurrency runtime with a work-stealing scheduler for **Lean 4**. The basic thrust is that we can use
techniques found in tokio and node to get a runtime for concurrency that is on par with other highly concurrent
languages but which lives in a proof assistant. The basic trick is to use **data, not closures** — i.e.
defunctionalisation rather than vanilla `do`.

The concurrency engine is quite general but we have demonstrated it with an HTTP/1.1 server. A benchmark which gives
you a flavour of our current performance: a keep-alive with a per-request handler (`bench/threeway.sh`):

| server | C=1 req/s | C=8 | C=32 |
|---|---|---|---|
| Node 22 | 45 380 | 139 857 | 101 042 |
| **leanin** | **29 932** | **42 241** | **37 705** |
| shipped `Std.Http.Server` | 2 166 | 3 363 | 2 687 |

**~14× the Lean HTTP server that ships with the toolchain**, and within 1.5× of Node at one connection. We
still have some work to hit Node 22 performance, but is within spitting distance. More details here: [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md).

## Development Status

**M2 closed, M3 under way** ([`PLAN.md`](docs/PLAN.md) §0, [`docs/decisions.md`](docs/decisions.md)). The
pure model is implemented and machine-checked (`LeanIn/Model/`, `LeanIn/Theory/World.lean`) with an executable
probe for its vacuity; `LeanIn/Theory/Bridge.lean` states the nine primitive contracts about the native
operations, each with a control and three with native trace scenarios under `tests/`; and the runtime serves
real connections on carriers of our own, which is what the table above measures.

## Design

Our current focus is a single threaded carrier with high concurrency. In order to achieve that we borrow liberally
from the following:

- **Tokio** — the scheduler architecture, taken component by component from the Rust source. The reference copy
  is `Vendor/tokio/`, and [`docs/tokio-map.md`](docs/tokio-map.md) anchors every borrowing to a line in it: the
  multi-thread work-stealing flavour (per-worker local queue, shared inject queue, stealing), the LIFO slot, the
  current-thread flavour, the blocking pool, `defer`, `block_in_place`.
- **Node** — the I/O completion model. Our socket layer is a libuv loop of our own (`c/netuv.c`) but has Node's
  shape.

## Stat Machines for async

Our client code reads like a monadic async similar to what ships with Lean — `do`, with `←` for a suspension — but
our version is **compiled** and not threaded through closures with `bind`.

`asyncMachine` (`LeanIn/Async.lean`) lowers a `do` block to a **flat state machine**: with one constructor per
suspension point, carrying the variables which live across invocations as *data* (after a liveness analysis); a `step`
function the driver matches on; pure code inlined into the current state; and `if`, `while`, `for`, `break` and
`continue` lowered to transitions between states. Suspensions are marked `await`. Parameters are either constant
**step parameters** (the connection, the clock, the handler) or **threaded fields** (the H1 machine — state 0
carries it and `recurse` passes its current value back, which is how keep-alive state survives across requests).

A suspension allocates no `Join` cell, `Item`, inject or carrier fire. A completion **resumes its continuation
on the loop thread** — raw delivery — so resuming is a direct call rather than a wakeup round trip.

Details are in [`docs/async-vm.md`](docs/async-vm.md).

## Install

The toolchain uses both lake and nix.

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

That build also compiles the socket shim: `c/netuv.c` is an `extern_lib`, so Lake compiles and archives it and
links it into the executables that use the socket layer. It needs **libuv** — `uv.h` to compile, `-luv` to link —
which is the one dependency outside the Lean toolchain. The dev shell provides it; a build outside the shell
needs `libuv` and its development headers installed.

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

## Licence

Apache License 2.0 — the full text is [`LICENSE`](LICENSE), and the attribution it asks for is in
[`NOTICE`](NOTICE).

Copyright 2026 Scidonia Limited.
