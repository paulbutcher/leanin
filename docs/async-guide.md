# Writing a server with `async`

`async` compiles a `do`-notation body into a state machine that runs on the runtime's carriers and
event loop. Every `await` on a classified effect becomes a suspension: the machine's state is a constructor
holding its live values, the effect parks, and the completion resumes the state on a carrier. Nothing here
needs a stock `Task`, a `Std.Http.Server` connection loop, or a continuation-passing rewrite by hand.

This page describes the compiled surface on `main`, including the result-bearing declarations added after
`v0.2.0`. The `v0.2.0` tag carries the effect and failure-policy repairs but not `async def`; the assessment of
the surface, and the items still open, is
[`notes/LeanIn_Authoring_Surface_Handoff.md`](notes/LeanIn_Authoring_Surface_Handoff.md). Every command below was run.

## The shape

There is one declaration form: `async def name (c : C) … : T := do …`. The public `name` returns
`Task.EAsync IO.Error T`; the compiler generates the internal runner and its completion. There is no
author-written `onDone`.

```lean
async def readSeven (src : LeanIn.Runtime.Conn) : ByteArray := do
  let chunk := await (LeanIn.Runtime.Io.recvRaw src 7)
  return chunk
```

The generated internal runner is `name.run`; it takes a `LeanIn.Async.Completion T` (`done` and `fail`) after
the authored parameters. A compiled machine calls another with `await (name.run …)`, and the classifier fills
that completion; the caller sees the result `T`, not an `Except`.



- The first parameter after the name is the **carried value** — a connection for a connection loop, a
  listener for an accept loop — and its declared type is the type the generated `step` and `run` take.
- The remaining parameters are threaded through the machine's states. A parameter the body does not rebind
  keeps its value across `recurse`; one bound by `let … := await …` advances.
- A machine ends a path in `recurse` (re-entering with the current fields), `halt`, a close, `return`, or
  `throw`. The compiler rejects a path that can fall off the end.
- The receiver and size written in the `await` are the ones lowered. `await (Io.recvRaw src 7)` reads at most
  seven bytes from `src`; it is not rewritten to the machine's carried connection or to a default size.
- A send's result is `Except IO.Error Unit`: `let r := await (Io.sendRaw c bs)` binds it, and
  `await (Io.sendRaw c bs)` discards it and continues. Binding changes what the body can inspect, not whether
  the path runs.
- Layouts are otherwise not observable.

## Result-bearing declarations

`async def name (c : C) … : T := do …` is the compiler-owned-result form. The public `name` returns
`Task.EAsync IO.Error T`; `return e` delivers `.ok e` through a generated completion parameter the author never
names. The internal `name.run` takes a `LeanIn.Async.Completion T` — `done` and `fail` — so a machine-to-machine
call `await (name.run c …)` keeps the payload `T`, and a failure from the callee is delivered to the caller's
own failure channel. `name.spawn push …` yields a `RawCell (Except IO.Error T)`.

A result-bearing declaration is called from `IO` or from `Runtime.run`, and from a compiled machine with
`await (name.run …)`; the result payload is `T`, not `Except`. An uncaught `throw` is delivered as `.error` and
ends the path; a path that never reaches `return`, `throw`, or another terminal never resolves.

```lean
async def immediate (u : Unit) : Nat := do
  return 42

async def afterTimer (u : Unit) (clock : LeanIn.Runtime.Clock) : Nat := do
  let slept : Unit := await (LeanIn.Runtime.Io.sleepRaw clock.schedule 5)
  return 43
```

`tests/async-result.sh` runs an immediate return and a return after a timer. This cut is the first proposal
slice: results and `return` exist, and the public call is ordinary typed code. Result-bearing
machine-to-machine calls, compiler-owned failure delivery for an unhandled `throw`, and the scope API remain
in the handoff.

## The effect set

These are the forms that compile. Anything else in `await` position is rejected with
`async: unsupported effect`.

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

The machine handed to `VM.runAsync` may be a `VM.requestScope` of a handler: the await then yields that
machine's `Outcome` — a value, an ordinary error, or a transport abort — and the driver matches on the three
cases. The scope is inside the machine, so the compiled form is still the same syntactic `VM.runAsync m` and the
compiler needs no new effect (D23).

## Names and ascriptions

Every name the body binds is a field of the next state. A field carries a type in one of three ways:

1. the value's type is known from the effect (the table above);
2. the binding is ascribed — `let n : Nat := await (…)` — and the ascription is **checked on the binder**, so
   a mismatch fails at elaboration whether the value is used later or not;
3. the type cannot be inferred, in which case compilation fails with
   `async: cannot determine the type of state field …` rather than guessing `Unit`.

Values that live across a suspension need (1) or (2). A `let` that is dead before the next suspension is
dropped, but its ascription is still elaborated against the bound value.

## Running what you compiled

```lean
let l ← LeanIn.Runtime.Listener.bind (LeanIn.Runtime.loopback 8085)
let e ← LeanIn.Sched.Executor.new LeanIn.Task.Item 256 1
let push := LeanIn.Runtime.sharedPush e
```

A result-bearing call needs no push of its own: `name args` is a `Task.EAsync`, and
`LeanIn.Runtime.run e (name args)` drives it to `Except IO.Error T`. `push` is the executor's inject for
`spawn`, `acceptRaw`, and the internal runner when a long-lived machine is started without awaiting a terminal.

## The complete server

`LeanIn/Exe/Hello.lean` is a bind/serve/handler server whose serving path is a set of machines: a connection
machine, an accept loop that spawns one per connection, and two child machines used to build each answer. It
covers the shapes a server actually uses: a read with a deadline, a spawn-and-select race, a timer, keep-alive
recursion, and a close whose refusal is reported. Build and run it:

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

### A request with a deadline

`readRequest` races the read against a stated instant. The result distinguishes a stalled read (`none`), an
end of stream (`some (.ok none)`), bytes, and a transport failure. The failure is **closed before it is
raised**, so the connection has one cleanup owner:

```lean
async def readRequest (c : LeanIn.Runtime.Conn) (clock : LeanIn.Runtime.Clock) :
    Option ByteArray := do
  let rt := await (LeanIn.Runtime.Io.recvTimeoutRaw c clock.schedule 5000 65536)
  match rt with
  | none => return none
  | some (.ok none) => return none
  | some (.ok (some bs)) => return some bs
  | some (.error e) =>
      let closed := await (LeanIn.Runtime.Io.closeRaw c)
      if closed then throw e else throw (IO.userError s!"{e}; and the loop refused the close")
```

The deadline is a clock effect, not a stock sleep: a harness clock advances it and a live clock arms a wheel
entry. `clock.schedule` is the same function the read uses, so a test can move the deadline without changing the
machine.

### Spawn, select, and a timer

The body comes from two child machines at different delays; the parent selects the first completion. This is
`spawn` plus `selectRaw`, with a timer as the thing that makes the race meaningful:

```lean
async def helloAfter (c : LeanIn.Runtime.Conn) (clock : LeanIn.Runtime.Clock)
    (d : Std.Time.Millisecond.Offset) (payload : ByteArray) : ByteArray := do
  await (LeanIn.Runtime.Io.sleepRaw clock.schedule d)
  return payload

async def helloBody (c : LeanIn.Runtime.Conn) (push : LeanIn.Task.Item → BaseIO Unit)
    (clock : LeanIn.Runtime.Clock) : ByteArray := do
  let hFast : LeanIn.Runtime.RawCell (Except IO.Error ByteArray) :=
    await (helloAfter.spawn push c clock 1 "hello".toUTF8)
  let hSlow : LeanIn.Runtime.RawCell (Except IO.Error ByteArray) :=
    await (helloAfter.spawn push c clock 25 "slow".toUTF8)
  let winner : Nat × Except IO.Error ByteArray := await (LeanIn.Runtime.selectRaw hFast hSlow)
  match winner.2 with
  | .ok body => return body
  | .error e => throw e
```

Two details matter. `spawn` returns a `RawCell`; `selectRaw` waits on two cells of the same type and returns
the winning index and value. The loser is **not cancelled**: its timer still fires and its cell resolves, but
no one awaits it. That is the intended shape for a race with no side effects. `helloConn` then joins the
body-building machine with `await (helloBody.run c push clock)`, writes the response, and closes.

### Keep-alive is just recursion

`helloKeep` reads, answers, and `recurse`s with the connection carried forward. No loop variable and no
call-stack growth: the compiler re-enters the same state with the current fields.

```lean
async def helloKeep (c : LeanIn.Runtime.Conn) (push : LeanIn.Task.Item → BaseIO Unit)
    (clock : LeanIn.Runtime.Clock) : Unit := do
  let req : Option ByteArray := await (readRequest.run c clock)
  match req with
  | none =>
      let closed := await (LeanIn.Runtime.Io.closeRaw c)
      if closed then return () else throw (IO.userError "helloKeep: the loop refused the close")
  | some _ =>
      let body := await (helloBody.run c push clock)
      await (LeanIn.Runtime.Io.sendAllRaw c #[response body false])
      recurse
```

The accept loop chooses between this and the close-after-one machine; both are spawned per connection with
`helloKeep.spawn`/`helloConn.spawn`, and the handle is deliberately discarded so one connection's failure stays
at that connection.

### Which primitive for which job

| job | primitive in this page |
|---|---|
| fan out and join a specific child | `Foo.spawn push c …` then `RawCell.await h` |
| take the first of two completions | `VM.selectRaw h0 h1` |
| bound a read | `Io.recvTimeoutRaw c clock.schedule d size` |
| wait a stated interval | `Io.sleepRaw clock.schedule d` |
| keep a connection alive | `recurse` with the connection carried |
| run a background child | `Foo.spawn` and discard the handle |
| close and report a refusal | `Io.closeRaw c`, then `throw` if `false` |
| answer a request | `Io.sendAllRaw c #[head, body]` |

Join and select are both ordinary awaits: `RawCell.await h` parks on one handle, while `selectRaw` parks on
two and returns the winner's index and value. A discarded spawn handle is a background task; there is no
supervision unless the loop awaits it.

### What the example does not do

It does not supervise the spawned connection handles, and it has no graceful-stop path: the accept loop ends
only when `acceptRaw` can no longer complete. The shipped `Http.Server` adds request scopes, a drain deadline
and multi-carrier serving; the compiled example stays small enough to read.

## Cleanup ownership

A connection failure has exactly one cleanup owner, so no failure closes a connection twice and none leaves it
open:

- an **asynchronous completion failure** (a read or write that the loop reports as failed) is closed by the
  loop, which raises if the shim refuses that close;
- an **immediate submission refusal** (the shim rejects the read or write itself, so no completion will ever
  arrive) is closed by the primitive that made the submission, which raises if the close is refused too;
- an **end of stream** is closed by the machine, which raises if the close is refused.

A send returns its `Except IO.Error Unit` whether or not the body binds it: an unbound send discards the value
and continues, so binding changes what the body can inspect, not whether the path ends. The cleanup owners
above are unchanged; a failed send leaves the connection closed by the loop, and the next operation on it
fails at that operation.

## What fails loudly

- An `await` on an unserialized form: `async: unsupported effect`.
- A machine call whose name is not a compiled machine's tagged `run`, or whose arity is wrong.
- A spawn whose target is not the generated spawner of a tagged run.
- A `let` pattern: `async: destructuring let is not supported` — bind a name and project.
- A path that can fall off the end: `async: a path does not end in recurse, a close, or halt`.
- A field whose type cannot be determined, or whose ascription mismatches:
  `has type Unit but is expected to have type Nat`.

The diagnostics fixture checks these rejections as compile failures:

```bash
nix develop -c bash tests/async-diagnostics.sh
```

## Limits, stated

- The effect set is closed; a body needing anything else awaits a `VM.runAsync` of the interpreted machine,
  which can express dynamic effects at the cost of an interpreter step.
- Machine calls take one continuation last; `select` is over two cells of one type (no heterogeneous race).
- A declaration's public `name` is an `EAsync` value; compiled code calls its internal `name.run`, which the
  classifier fills with a `Completion`. `await (name …)` on the public value is not a classified effect.
- A result-bearing machine resolves on `return` or `throw`. A `throw` becomes `.error` on the public
  `EAsync`; it is not a catchable local exception in this compiled subset.
- A running handler is not cancelled by a scope of its own: closing a connection ends the I/O but not a
  suspended computation. A **peer-I/O failure** does end the request: a failed body read, a stall, a peer close
  mid-body or a failed response send is a VM abort, which the streaming driver's `requestScope` turns into an
  `aborted` outcome, so the connection closes as a transport error with no further response attempted — bytes
  already sent stand — instead of sitting parked on a read whose peer is gone (D23). That is not arbitrary
  cancellation — a handler parked on a leaf nothing falsifies still never returns, and no child computation is
  cancelled.
- The `hello` example is single-carrier: the accept loop, the connection's effects and its resumes run on one
  thread. The shipped `Http.Server` supports `workers=N` through the multi-carrier entry; the compiled example
  deliberately stays single-carrier.
- A spawned handler's outcome is not supervised by the example's loop (the handle is discarded): each
  connection's failure is handled at that connection's own boundary — an unbound send discards its failure result and does not
  end the path (the loop still closes the failed connection) — and reaches no other connection. A loop that must observe its children awaits their handles; a child that can
  end without resolving one (an end of stream before its continuation is reached) makes that wait unbounded,
  which is why this loop does not.
- The example has no graceful-stop path: the accept loop runs until the process is stopped, and a signal ends
  the process without draining connections in flight. `Listener.accept` fails once the loop is stopped, which
  is the loop's only terminal and the one outcome `main` reports.
