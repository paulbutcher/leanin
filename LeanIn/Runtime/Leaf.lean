module

import Std
import Std.Async.Signal
import LeanIn.Runtime.Basic
import LeanIn.Runtime.Io
import LeanIn.Task.Error


public section
/-!
# The leaf seam

`interface.md` §4: the leaf operations are not ours. Timers, sockets, DNS, signals and processes stay in
`Std.Async`, and they are reached across one seam — "an external event attaches a continuation that pushes into
`inject` and notifies". This file is that seam, in both directions.

**Inward** (what this file does): a leaf produced by `Std.Async` becomes something our tasks can await without
blocking. The continuation is registered on the leaf's `Task`, and all it does when it fires is *enqueue* our
resume — so nothing of ours runs on the thread that completed the work.

**`Std.Async` is referenced here and, by the boundary W1 sets, nowhere else in the tree.** Before this file the
runtime called no `Std.Async` at all; the platform library was in the build only because `Std.Internal`
re-exports it publicly. Everything outside this module stays on the C++ primitives.

## What the conversions carry, and what they do not

* **The panicking ones carry no failure.** `awaitTask`, `awaitPromise` and `awaitAsync` panic when the leaf
  fails, rather than delivering the error to the awaiter and leaving it parked forever. That is right for a
  client that has decided a failure is a defect; the `…E` variants below are the same seam with the failure in
  the *value* — `EAsync ε α` is `Async (Except ε α)` — which is what a server uses, because a peer going away
  mid-request is an ordinary event.
* **A continuation runs whether or not we keep it.** `IO.bindTask`'s own documentation is explicit: "Unlike pure
  tasks created by `Task.spawn`, tasks created by this function will run even if the last reference to the task is
  dropped" (`Init/System/IO.lean:266-269`). So a registration does not have to be retained for its continuation to
  fire: dropping one sets that task's cancellation flag and leaves it running, which stops nothing here, because
  the continuation it holds never checks the flag. The registry is kept for two reasons, and a dropped entry losing
  work is neither of them: `pending` reads it, because registrations still outstanding are the part of "in flight"
  the pool's counters cannot show, and each entry carries the token of the computation that left it, which is what
  lets a cancellation retire its own work's entries rather than only stop new steps from being scheduled. The
  conversions take it from the caller, which is also why there is no `MonadLift` instance: it is runtime-scoped
  state, not something an instance can carry.
-/

namespace LeanIn.Runtime

/-- Where a conversion's registrations are kept alive: the token of the computation that awaits, and the stock
`Task` whose completion resumes it.

The token is what makes an entry *attributable* — to the computation that left it, and to the cancellation that
should retire it. Without it a registry can only grow, because nothing can tell an entry that will never run again
from one that is simply still waiting.

**The invariant relied on.** Every write to the registry happens on the carrier: `Hooks.add` and `Hooks.retire`
are the work of a step, so the list is only ever mutated by carrier threads, one step at a time, and no foreign
thread writes it. The blocking pool adds no carrier step and no writer of the list: its job thread resolves its
own job's promise and nothing else. The only entry that resolution can settle is the one the job's own submission
registered, whose stock `Task` it drives to finished — the same fact the next carrier-side `Hooks.add` would
record — and it never touches another computation's entry. A job thread resolving only its own promise is what
keeps the registry's writers on the carrier. -/
structure Hooks where
  /-- The registrations: the token of the computation that awaits, and the stock `Task` whose completion
  resumes it. -/
  entries : IO.Ref (List (Task.Cancel × _root_.Task Unit))
  /-- Registrations since the last compaction. See `Hooks.add`. -/
  since   : IO.Ref Nat

def Hooks.new : IO Hooks := do
  return { entries := ← IO.mkRef [], since := ← IO.mkRef 0 }

/-- How many registrations pass between compactions. A compaction costs one walk of the registry, so a period
of `n` makes the walk's share of a registration `1/n` of the list's length: large enough that the sweep is
noise beside the registration, small enough that the list tracks the registrations actually in flight. -/
def Hooks.compactEvery : Nat := 256

/-- **Drop the entries that can no longer run.** An entry is dropped when its stock `Task` has finished — it
holds nothing that can still run — or when its token is set, which means the computation that left it was
cancelled and its continuation will be skipped. -/
def Hooks.compact (hooks : Hooks) : IO Unit := do
  let ts ← hooks.entries.get
  let mut live := []
  for e in ts do
    if (← IO.getTaskState e.2) != .finished then
      unless ← e.1.isSet do live := e :: live
  hooks.entries.set live

/-- **Register a conversion's continuation.** A registration appends and returns: the continuation is kept
alive by the `bindTask` that produced it, so what the registry is *for* is the reading (`pending`, and a
cancellation retiring its own work) rather than delivery, and a registration needs no sweep to be correct.

It used to sweep on every registration — walking the whole list, calling `IO.getTaskState` on each entry — which
is linear in the registrations in flight and therefore in the timers a service leaves parked. `compactEvery`
registrations later the sweep runs once and the walk is amortised to `1/compactEvery` of the list. -/
def Hooks.add (hooks : Hooks) (c : Task.Cancel) (t : _root_.Task Unit) : IO Unit := do
  hooks.entries.modify fun ts => (c, t) :: ts
  let n ← hooks.since.modifyGet fun n => (n + 1, n + 1)
  if n % Hooks.compactEvery == 0 then
    Hooks.compact hooks

/-- **Retire every cancelled computation's registrations.** What `Runtime.cancel` calls, so that the count drops
where the cancellation happens rather than at whatever the next await is: an entry whose token is set is work that
will never run, and `pending` must not go on counting it as in flight. -/
def Hooks.retire (hooks : Hooks) : IO Unit := do
  let ts ← hooks.entries.get
  let mut live := []
  for e in ts do
    unless ← e.1.isSet do live := e :: live
  hooks.entries.set live

/-- **How many registrations the registry holds**, in flight or not: the list's own size. -/
def Hooks.size (hooks : Hooks) : IO Nat := do
  return (← hooks.entries.get).length

/-- **How many registrations one computation still holds.** Entries are attributable, so this can be asked about a
particular computation instead of about the runtime: a cancellation is supposed to remove *the cancelled work's*
registrations, and a total that includes the cancelling computation's own last one is neither specific nor stable —
a step resumed from a leaf has itself just left a registration whose finished-marking is another thread's business.

Unlike `pending` it does not skip a set token. An entry whose computation has been cancelled and not yet retired is
exactly the thing this exists to see, so skipping it would make the reading unable to show the difference. -/
def pendingFor (hooks : Hooks) (c : Task.Cancel) : IO Nat := do
  let ts ← hooks.entries.get
  let mut n := 0
  for e in ts do
    if e.1.id == c.id then
      if (← IO.getTaskState e.2) != .finished then
        n := n + 1
  return n

/-- **How many registrations are still outstanding.** A hook stops being pending when its leaf completes — that
is when the continuation it holds runs — so this is the part of "in flight" that a model of pool items cannot
see: a task parked on a leaf holds no pool item at all, and a driver that stopped there would abandon it. Reading
it after a run returns is the conformance check that the model's invariants cannot state. -/
def pending (hooks : Hooks) : IO Nat := do
  let ts ← hooks.entries.get
  let mut n := 0
  for e in ts do
    if (← IO.getTaskState e.2) != .finished then
      unless ← e.1.isSet do
        n := n + 1
  return n

/-- **The step that does the work**, factored out so `awaitTask` and `awaitAsync` share one path: register a
continuation that enqueues, and return.

`ctx.resumeShared` is the runtime's **shared** scheduling route, so the completion is delivered as fresh work on
the shared list rather than run on whatever thread completed the leaf: the completing thread is not the owning
carrier in general, so a local push there would land in a parked owner's queue with nothing to wake it. The item
is `Item.ofDeferred`: it carries the awaiting computation's token and ambient context, and the worker that takes
it from the shared list supplies the route its continuation re-enqueues on. -/
def awaitTaskStep {α : Type} (hooks : Hooks) (t : _root_.Task (Except IO.Error α))
    (k : α → Task.Ctx → IO Unit) (ctx : Task.Ctx) : IO Unit := do
  let hooked ← BaseIO.bindTask t (fun r => do
    match r with
    | Except.ok v    => ctx.resumeShared (Task.Item.ofDeferred ctx (k v))
    | Except.error e => panic! s!"awaitTask: the awaited task failed: {e}"
    return _root_.Task.pure ())
  hooks.add ctx.cancel hooked

/-- **Wait for a stock `Task`** without blocking. -/
def awaitTask {α : Type} (hooks : Hooks) (t : _root_.Task (Except IO.Error α)) : LeanIn.Task.Async α :=
  ⟨fun k ctx => awaitTaskStep hooks t k ctx⟩

/-- **Wait for a promise's result** — the shape `Std.Async`'s leaves resolve, since `Async.sleep` and its
relatives are `ofPurePromise` over the reactor. -/
def awaitPromise {α : Type} (hooks : Hooks) (p : IO.Promise (Except IO.Error α)) : LeanIn.Task.Async α :=
  awaitTask hooks (Std.Async.AsyncTask.ofPromise p)

/-- **Any `Std.Async` computation as one of ours.** `Async α` is `BaseIO (MaybeTask (Except IO.Error α))`: run
it, and if it hands back a `Task`, register our resume on it. -/
def awaitAsync {α : Type} (hooks : Hooks) (a : Std.Async.Async α) : LeanIn.Task.Async α :=
  ⟨fun k ctx => do
    let mt ← Std.Async.BaseAsync.toRawBaseIO a
    match mt with
    | .pure (.ok v)    => k v ctx
    | .pure (.error e) => panic! s!"awaitAsync: the computation failed: {e}"
    | .ofTask t        => awaitTaskStep hooks t k ctx⟩

/-- **Wait for a stock `Task`, carrying its failure.** The sibling of `awaitTask`, and the difference is the whole
point of `EAsync`: where that one says a failure has nowhere to go and panics, this returns it — which is what a
socket needs, because a client that goes away mid-request is an ordinary event rather than a defect.

The registry and the one-continuation shape are the same; only the reading of the result differs. The delivery is
the shared route's, as `awaitTaskStep`'s is. -/
def awaitTaskE {α : Type} (hooks : Hooks) (t : _root_.Task (Except IO.Error α)) : Task.EAsync IO.Error α :=
  ⟨fun k ctx => do
    let hooked ← BaseIO.bindTask t (fun r => do
      ctx.resumeShared (Task.Item.ofDeferred ctx (k r)); return _root_.Task.pure ())
    hooks.add ctx.cancel hooked⟩

/-- **Wait for a promise's result, carrying its failure.** -/
def awaitPromiseE {α : Type} (hooks : Hooks) (p : IO.Promise (Except IO.Error α)) : Task.EAsync IO.Error α :=
  awaitTaskE hooks (Std.Async.AsyncTask.ofPromise p)

/-- **Any `Std.Async` computation, carrying its failure.** -/
def awaitAsyncE {α : Type} (hooks : Hooks) (a : Std.Async.Async α) : Task.EAsync IO.Error α :=
  ⟨fun k ctx => do
    let mt ← Std.Async.BaseAsync.toRawBaseIO a
    match mt with
    | .pure r   => k r ctx
    | .ofTask t => (awaitTaskE hooks t).step k ctx⟩

/-- The POSIX number of a `Std.Async.Signal`, for the shim's `uv_signal_start`. `Std.Async.Signal`'s own
mapping is private, so the standard Linux assignments are spelled out here. -/
private def signalNumber : Std.Async.Signal → Nat
  | .sighup => 1
  | .sigint => 2
  | .sigquit => 3
  | .sigtrap => 5
  | .sigabrt => 6
  | .sigusr1 => 10
  | .sigusr2 => 12
  | .sigalrm => 14
  | .sigterm => 15
  | .sigurg => 16
  | .sigchld => 17
  | .sigcont => 18
  | .sigtstp => 20
  | .sigttin => 21
  | .sigttou => 22
  | .sigxcpu => 24
  | .sigxfsz => 25
  | .sigvtalrm => 26
  | .sigprof => 27
  | .sigwinch => 28
  | .sigio => 29
  | .sigsys => 31

/-- **Wait for a process signal**, registered for `signum` and awaited through the seam.

The watcher is a `uv_signal_t` on *our* loop (`Io.signalWatch`), whose callback records a shim event the loop
thread dispatches — not a promise on a second libuv instance's loop, which is where a signal waited through the
standard library's own reactor comes from. The awaited cell is resolved with the signum by the loop's dispatch,
exactly as a socket completion resolves its parked operation, so the delivery travels the same path as every
other completion on the loop. `repeating` is the watcher's one-shot-or-continue choice. -/
def awaitSignal (_hooks : Hooks) (signum : Std.Async.Signal) (repeating : Bool) : Task.Async Int :=
  ⟨fun k ctx => do
    let cell ← LeanIn.Task.Join.new
    Io.signalWatch (signalNumber signum) repeating cell ctx.resumeShared
    (LeanIn.Task.Async.await (show LeanIn.Task.Task Int from ⟨cell, ← LeanIn.Task.Cancel.new⟩)).step k ctx⟩

/-- **Cancel a computation**: its steps stop being run, its registrations are retired, and an awaiter of its
handle is woken with `v`.

`Task.cancel` does the stopping and the waking; this adds the registry half, which is why it is here rather than
there. An entry belongs to the computation that left it, so a cancelled computation's entries are work that will
never run: retiring them makes `pending` drop at the cancellation rather than at whatever the next await happens
to be, which is what lets a drain read "nothing outstanding" as soon as the work it cancelled is gone.

`v` is the caller's: a connection's cancellation is `.error (.userError "…")` at a server's call site.

`push` is the **cancelling step's own route** — `Task.Async.push` — because the cancellation resolves the
cancelled handle's cell, and a resolution delivers the cell's waiters as items on the resolving step's queue. A
caller that is not running a step — a thread that holds no queue — passes the runtime's shared route instead
(`Runtime.sharedPush`), which unparks a waiter under its own lock.

Both halves are called from inside a step, on the carrier. Retiring the registrations reads the registry, rebuilds
it and writes it back — a list operation, not one atomic update — so two cancellations running concurrently would
race it. That is stated here because this is a public `IO` operation and its callers cannot see the registry; a
second carrier is where it becomes a defect rather than a comment. -/
def cancel {α : Type} (hooks : Hooks) (t : Task.Task α) (push : Task.Item → BaseIO Unit) (v : α) : IO Unit := do
  t.cancel push v
  hooks.retire

/-- **Race a handle against others**: the first of them to become ready wins, and every non-winner is cancelled
with `v`.

`select` decides which handle won and leaves the rest running; this applies `cancel` to each loser, so a loser
resolves with `v` exactly once and immediately, no step of it runs afterwards, and its registrations are retired.
A loser that finished before the race returned keeps its own value: a cancellation never replaces a value that
exists. Each cancellation delivers its loser's waiters on the racing step's own route, which is this step's. -/
def race {α : Type} (hooks : Hooks) (v : α) (h : Task.Task α) (hs : List (Task.Task α)) :
    Task.Async (Nat × α) := do
  let r ← Task.select h hs
  let push ← Task.Async.push
  let rec go : List (Task.Task α) → Nat → Task.Async Unit
    | [], _ => pure ()
    | t :: ts, i => do
        if i != r.1 then monadLift (cancel hooks t push v)
        go ts (i + 1)
  go (h :: hs) 0
  return r

end LeanIn.Runtime

end
