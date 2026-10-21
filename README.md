<p align="center">
  <img src="docs/assets/LeanIn.png" alt="leanin" width="720">
</p>

# `LeanIn`

[![CI](https://github.com/scidonia/leanin/actions/workflows/ci.yml/badge.svg)](https://github.com/scidonia/leanin/actions/workflows/ci.yml)

LeanIn is a concurrency runtime with a work-stealing scheduler for **Lean 4**. The basic thrust is that we can use
techniques found in tokio and node to get a runtime for concurrency that is on par with other highly concurrent
languages but which lives in a proof assistant. The basic trick is to use **data, not closures** — i.e.
defunctionalisation rather than vanilla `do`.

The library is the concurrency toolkit: `import LeanIn` brings in the runtime, scheduler, task and async
interfaces, data structures and their model. The HTTP/1.1 protocol and serving layer live in `LeanIn.Http`, part
of the same library; LeanIO consumes that serving layer as its native backend. Requests to
`/bench`, both sides pinned to distinct P-cores:

| shape | server | C=1 | C=8 | C=32 |
|---|---|---|---|---|
| depth 1 | Node 22 | 64 100 | 140 011 | 144 473 |
| depth 1 | **leanin** | **62 568** | **147 791** | **126 481** |
| depth 1 | shipped `Std.Http.Server` | 5 323 | 5 584 | 7 626 |
| pipe 16 | Node 22 | 164 090 | 168 179 | 177 930 |
| pipe 16 | **leanin** | **424 573** | **512 451** | **411 417** |
| pipe 16 | shipped `Std.Http.Server` | 7 472 | 11 436 | 12 462 |
| churn | Node 22 | 26 067 | 46 106 | 48 686 |
| churn | **leanin** | 16 128 | 42 115 | 39 992 |
| churn | shipped `Std.Http.Server` | 2 815 | 1 923 | 1 438 |
| **depth 1** | **leanin / Node** | **0.98×** | **1.06×** | **0.88×** |
| **pipe 16** | **leanin / Node** | **2.59×** | **3.05×** | **2.31×** |
| **churn** | **leanin / Node** | **0.62×** | **0.91×** | **0.82×** |

`C` is the number of concurrent connections; values are requests per second. Shapes: **depth 1** keeps one
request in flight per connection, **pipe 16** keeps sixteen in flight, **churn** opens one connection per
request. Measured on commit `554e3b0` with one invocation of `bench/screen.sh`; host load rose from ~2.5 to 8.1
during the run after Node's rows were taken, so the single readings and ratios are an illustration — the
paired instrument is `bench/paired.sh`. Method and ranges: [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md).

LeanIO — the router and HTTP framework — lives in its own fork at
[`scidonia/leanio`](https://github.com/scidonia/leanio), with LeanIn as a Lake dependency. It is no longer part of
this repository.

## Development Status

**The `async` workplan is closed (M1–M5)** ([`docs/async-workplan.md`](docs/async-workplan.md)):
sound authoring, composition, time as an effect, spawn and select, and accept — with the compiled server
example and the authoring guide. The roadmap's own status is in [`PLAN.md`](docs/PLAN.md) §0. The pure model
is implemented and machine-checked (`LeanIn/Model/`, `LeanIn/Theory/World.lean`) with an executable probe for
its vacuity; `LeanIn/Theory/Bridge.lean` states the nine primitive contracts about the native operations, each
with a control and three with native trace scenarios under `tests/`; and the runtime serves real connections
on a carrier of our own, which is what the table above measures.

## Design

Our current focus is a single threaded carrier with high concurrency. In order to achieve that we borrow liberally
from the following:

- **Tokio** — the scheduler architecture, taken component by component from the Rust source. The reference copy
  is `Vendor/tokio/`, and [`docs/tokio-map.md`](docs/tokio-map.md) anchors every borrowing to a line in it: the
  multi-thread work-stealing flavour (per-worker local queue, shared inject queue, stealing), the LIFO slot, the
  current-thread flavour, the blocking pool, `defer`, `block_in_place`.
- **Node** — the I/O completion model. Our socket layer is a libuv loop of our own (`c/netuv.c`) but has Node's
  shape.

## State machines for async

Our client code reads like a monadic async similar to what ships with Lean — `do`, with `←` for a suspension — but
our version is **compiled** and not threaded through closures with `bind`.

`async` (`LeanIn/Async.lean`) lowers a `do` block to a **flat state machine**: with one constructor per
suspension point, carrying the variables which live across invocations as *data* (after a liveness analysis); a `step`
function the driver matches on; pure code inlined into the current state; and `if`, `while`, `for`, `break` and
`continue` lowered to transitions between states. Suspensions are marked `await`. Parameters are **threaded
fields of state 0**: a parameter the body does not rebind keeps its value across `recurse` (the clock, the
handler), and one it rebinds advances (the H1 machine — which is how keep-alive state survives across
requests). The connection is the `step` function's own argument.

A suspension allocates no `Join` cell, `Item`, inject or carrier fire. A completion **resumes its continuation
on the loop thread** — raw delivery — so resuming is a direct call rather than a wakeup round trip. That is
also the scaling trade: every connection's steps and their resumes run on that one loop thread, which is the
ceiling the measurements below read.

Details are in [`docs/async-vm.md`](docs/async-vm.md).

## Install

The toolchain uses both lake and nix.

| File | For | Toolchain |
|---|---|---|
| `lean-toolchain` | `elan` users | `leanprover/lean4:v4.35.0` |
| `flake.nix` | `nix` users | the official `v4.35.0` binary release |

The nix path builds that release from nixpkgs' own derivation rather than installing through `elan`, because
`elan` resolves `lean-toolchain` by downloading from the network, which an offline run may not do. nixpkgs
tracks `nixos-unstable` with no revision written in the flake: `flake.lock` records the revision actually
resolved, and `nix flake update` advances it.

```sh
nix develop -c lake build          # the library and its proofs; nothing else is a default target
```

That build needs nothing but the Lean toolchain. The executables are built on demand — `lake exe controls`,
`lake exe server` — and **those** need one thing more: `c/netuv.c`, the socket shim, is an `extern_lib`, so Lake
compiles it, archives it and links it into every executable of this package, which needs **libuv** (`uv.h` to
compile, `-luv` to link). It is the only dependency outside the toolchain; the dev shell provides it, and a
build without it still gets the library.

4.35 rather than 4.34 is deliberate: `Std.WP`, the weakest-precondition framework the proof strategy leans on,
does not exist before 4.35.

One gotcha, because it looks like a code failure when it happens: the flake's `lean4` is an `overrideAttrs` of
nixpkgs' derivation, which no binary cache serves, so a store that lacks it compiles Lean from source — an hour
or more. Until the store has it, the same commands can run through the toolchain `lean-toolchain` names, which
`elan` provides at the same version; say which of the two ran.

`lake build` also prints the `#print axioms` audit from `LeanIn/Theory/Bridge.lean`, reporting what the model's
theorems rest on: the pure-model theorems rest on Lean's `propext`, `Quot.sound` and `Classical.choice`, and
the bridge theorems additionally name the primitive specifications they consume as axioms (`clock_spec`,
`lock_spec`, `unlock_spec`, `wait_spec`, `notifyOne_spec`, `notifyAll_spec`) — the trusted base
[`docs/proof-strategy.md`](docs/proof-strategy.md) describes.

## Run

```sh
nix develop -c lake exe controls        # runtime controls: the primitive bridge, executor scenarios, HTTP
nix develop -c lake exe dynamics        # the model probe: is each contract's hypothesis reachable?
nix develop -c lake exe server          # the HTTP server on our runtime, port 8080
nix develop -c lake exe stdServer       # the same response via the shipped Std.Http.Server, port 8090
nix develop -c lake exe h1bench         # the head-parse microbenchmark
nix develop -c lake exe defuncEcho      # the same echo: CPS closures against the compiled state machine
nix develop -c lake exe hello           # the compiled `async` server example, port 8085

nix develop -c bash tests/executor-contract.sh SC1    # one scenario (SC1..SC27)
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

`bench/threeway.sh` runs every arm on this box inside one invocation, in the same mode — a keep-alive
per-request handler, `bench/load.mjs`, `5 s` per point — across four arms: Node, the compiled driver, the
shipped `Std` server, and the compiled example (`hello keep`):

```sh
nix develop -c bash bench/threeway.sh          # levels 1 8 32
nix develop -c bash bench/threeway.sh 1 4 16   # chosen levels
```

Both sides are pinned to distinct cores (server 1, client 2 — `THREEWAY_SERVER_CPU` and `THREEWAY_CLIENT_CPU`
override), and the energy-performance preference must be `performance` for rows to be comparable; an unpinned
run lets the two sides compete for the same cores and moves the rows by up to 50 %. The table at the top of this
file is that run's three server rows; the compiled example it also drives is a control, not a server row. Read
the ratios, not the absolute figures:
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
| [`docs/tokio-workplan.md`](docs/tokio-workplan.md) | The eighteen deliverables of the current milestone, with the evidence each requires |
| [`docs/proof-strategy.md`](docs/proof-strategy.md) | Property ladder, three-layer architecture, trusted base, the hard parts |
| [`docs/primitive-theory.md`](docs/primitive-theory.md) | What the externs guarantee: axioms, discharge, control tests |
| [`docs/tokio-map.md`](docs/tokio-map.md) | What we are taking from Tokio, component by component, with line anchors |
| [`docs/async-vm.md`](docs/async-vm.md) | The defunctionalization approach: raw delivery, `VM`, `async` |
| [`docs/async-guide.md`](docs/async-guide.md) | Writing a server with `async`: result-bearing declarations, the callback integration form, the effect set, the rules, and the limits |
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
