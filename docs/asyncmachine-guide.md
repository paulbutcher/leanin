# Writing a server with `asyncMachine`

`asyncMachine` compiles a `do`-notation body into a state machine that runs on the runtime's carriers and
event loop. Every `await` on a classified effect becomes a suspension: the machine's state is a constructor
holding its live values, the effect parks, and the completion resumes the state on a carrier. Nothing here
needs a stock `Task`, a `Std.Http.Server` connection loop, or a continuation-passing rewrite by hand.

This page names what compiles, what fails loudly, and what the limits are. Every command below was run.

## The shape

```lean
asyncMachine hello (c : LeanIn.Runtime.Conn) (onDone : Except IO.Error Unit → IO Unit) := do
  let req := await (LeanIn.Runtime.Io.recvRaw c 65536)
  await (LeanIn.Runtime.Io.sendAllRaw c #[response])
  let closed := await (LeanIn.Runtime.Io.closeRaw c)
  onDone (if closed then .ok () else .error (IO.userError "hello: the loop refused the close"))
```

- The first parameter after the name is the **carried value** — a connection for a connection loop, a
  listener for an accept loop — and its declared type is the type the generated `step` and `run` take.
- The remaining parameters are threaded through the machine's states. A parameter the body does not rebind
  keeps its value across `recurse`; one bound by `let … := await …` advances.
- A machine ends a path in `recurse` (re-entering with the current fields), `halt`, a close, or a call to
  its continuation. The compiler rejects a path that can fall off the end.
- Layouts are not observable: `await (LeanIn.Runtime.Io.sendRaw c bs)` discards the outcome, while
  `let r := await (LeanIn.Runtime.Io.sendRaw c bs)` binds the whole `Except`.

## The effect set

These are the forms that compile. Anything else in `await` position is rejected with
`asyncMachine: unsupported effect`.

| form | resumes with |
|---|---|
| `Io.recvRaw c size` / `Io.recvRaw c` | `ByteArray` (end of stream closes the connection) |
| `Io.recvTimeoutRaw c clock.schedule d size` | `Option (Option ByteArray)` |
| `Io.sendAllRaw c chunks` / `Io.sendRaw c bs` | `Except IO.Error Unit` |
| `Io.closeRaw c` | `Bool` (whether the loop accepted the close) |
| `Io.sleepRaw sched d` | `Unit` |
| `Io.acceptRaw l push` | `Except IO.Error Conn` |
| `Foo.run c …` | the callee machine's continuation payload |
| `Foo.spawn push c …` | `RawCell payload` (the child's completion handle) |
| `RawCell.await h` | the cell's value |
| `RawCell.new` / `RawCell.resolve cell v` | `RawCell α` / `Unit` |
| `VM.selectRaw h0 h1` | `Nat × α` (the winning index and value) |
| `VM.runAsync m` | the interpreted machine's result |

A machine call compiles to the callee's `run` with the caller's continuation as its last argument — no cell,
no carrier hop — so both machines' state layouts stay in that one call. `spawn` hands back a `RawCell`, and
`RawCell.await` on it is the join.

## Names and ascriptions

Every name the body binds is a field of the next state. A field carries a type in one of three ways:

1. the value's type is known from the effect (the table above);
2. the binding is ascribed — `let n : Nat := await (…)` — and the ascription is **checked on the binder**, so
   a mismatch fails at elaboration whether the value is used later or not;
3. the type cannot be inferred, in which case compilation fails with
   `asyncMachine: cannot determine the type of state field …` rather than guessing `Unit`.

Values that live across a suspension need (1) or (2). A `let` that is dead before the next suspension is
dropped, but its ascription is still elaborated against the bound value.

## Running what you compiled

```lean
let l ← LeanIn.Runtime.Listener.bind (LeanIn.Runtime.loopback 8085)
let e ← LeanIn.Sched.Executor.new LeanIn.Task.Item 256 1
let push := LeanIn.Runtime.sharedPush e
```

`push` is the executor's inject: the route every off-carrier delivery and every wake uses. Hand it to
`spawn`, `acceptRaw`, and the join that ends the run. Drive a server with `LeanIn.Runtime.run e prog` where
`prog` starts your machine; `Runtime.runVirtual` takes a harness clock for stated instants.

## The complete server

`LeanIn/Exe/Hello.lean` is a bind/serve/handler server whose serving path is three machines: a connection
machine, a spawn per connection, and an accept loop that recurses. Build and run it:

```bash
nix develop -c lake build hello
./.lake/build/bin/hello 8405 &
sleep 0.5
printf 'GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' | timeout 5 nc 127.0.0.1 8405
kill %1
```

The last command prints `HTTP/1.1 200 OK` with a five-byte body, `hello`. The scenario that checks it is
`SC27`:

```bash
nix develop -c bash tests/executor-contract.sh SC27
```

## Cleanup ownership

A connection failure has exactly one cleanup owner, so no failure closes a connection twice and none leaves it
open:

- an **asynchronous completion failure** (a read or write that the loop reports as failed) is closed by the
  loop, which raises if the shim refuses that close;
- an **immediate submission refusal** (the shim rejects the read or write itself, so no completion will ever
  arrive) is closed by the primitive that made the submission, which raises if the close is refused too;
- an **end of stream** is closed by the machine, which raises if the close is refused.

An unbound effect's error arm therefore does nothing: its failure is already owned. A bound effect hands the
`Except` to the body, whose path ends at that effect — the same owners apply.

## What fails loudly

- An `await` on an unserialized form: `asyncMachine: unsupported effect`.
- A machine call whose name is not a compiled machine's tagged `run`, or whose arity is wrong.
- A spawn whose target is not the generated spawner of a tagged run.
- A `let` pattern: `asyncMachine: destructuring let is not supported` — bind a name and project.
- A path that can fall off the end: `asyncMachine: a path does not end in recurse, a close, or halt`.
- A field whose type cannot be determined, or whose ascription mismatches:
  `has type Unit but is expected to have type Nat`.

The diagnostics fixture checks these rejections as compile failures:

```bash
nix develop -c bash tests/asyncmachine-diagnostics.sh
```

## Limits, stated

- The effect set is closed; a body needing anything else awaits a `VM.runAsync` of the interpreted machine,
  which can express dynamic effects at the cost of an interpreter step.
- Machine calls take one continuation last; `select` is over two cells of one type (no heterogeneous race).
- A running handler is not cancelled: closing a connection ends the I/O but not a suspended computation.
- The single-carrier driver runs the accept loop, the connection's effects and its resumes on one thread; a
  multi-carrier entry is not wired in the shipped executables.
- A spawned handler's outcome is not supervised by the example's loop (the handle is discarded): each
  connection's failure is handled at that connection's own boundary — an unbound send closes on failure — and
  reaches no other connection. A loop that must observe its children awaits their handles; a child that can
  end without resolving one (an end of stream before its continuation is reached) makes that wait unbounded,
  which is why this loop does not.
- The example has no graceful-stop path: the accept loop runs until the process is stopped, and a signal ends
  the process without draining connections in flight. `Listener.accept` fails once the loop is stopped, which
  is the loop's only terminal and the one outcome `main` reports.
