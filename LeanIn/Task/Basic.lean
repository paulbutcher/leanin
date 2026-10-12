import Std
import LeanIn.Sched.Executor

/-!
# The task layer

`docs/interface.md` §4: our own `Task`/`Async`, because `Std.Async` cannot be reused — it is
`BaseIO (MaybeTask α)` and every operation delegates to `Task`, so it cannot be driven on one carrier.

Three pieces:

* `Item` is what the executor holds: one step of some computation, ready to run.
* `Async α` is a **scheduleable computation**, in continuation-passing style: `step k ctx` runs it until it
  either finishes — calling `k` — or reaches something it must wait for, in which case it registers a
  continuation and returns. It never blocks the thread, which is what makes a single carrier enough.
* `Task α` is the **handle**: the cell its value lands in, and where an awaiter leaves its continuation.

`resume` is *how to schedule*, and it is one function for two jobs: continuing a computation that yielded, and
starting a child. That is why this layer needs no executor of its own — the runtime supplies the function and
decides whether scheduling means the local slot or the shared queue.

**Awaiting is the O3 seam turned inward.** An external event is "attach a continuation that pushes into the
queue and notifies"; here the event is our own task finishing, and the continuation an awaiter leaves is pushed
back onto the executor the same way. So there is one path, whether the completer is this task, another task, or
a stock `Task` on a pool worker — and that path never runs anything on the completing thread.

**The name collides with core's `Task`, but only inside this library.** `LeanIn.Task` shadows `_root_.Task` for
files under `LeanIn/`, so code in this tree that wants the stock one — `IO.asTask`'s `Task.Priority.dedicated`
in the test clients — spells it `_root_.Task`. The interface names these two types, so the collision comes with
the interface rather than from the layout.

**Where a route comes from, and the six sites the rule had to reach.** A route is never captured at a creation
site: `Ctx` carries the runtime's route *table* (`routeAt`), a step's own re-enqueue is read for the worker that
fires it, and a continuation another worker resolves is delivered as an item — `Item.ofDeferred` — whose action
re-binds the waiting computation's context (`Ctx.rebind`) at the index it is fired with, so the route it
re-enqueues on is that worker's and its token and ambient context stay the waiting computation's. The
registrations a *different* worker's step resolves are the sites a captured route made off-owner, and each was
re-read one by one:

| site | before | after |
|---|---|---|
| `Async.await` (`Task/Basic.lean`) | the awaiter's route, called on the resolver's thread | an item on the resolver's own queue |
| `select`'s final continuation (`Task/Basic.lean`) | the awaiter's route, called on the resolver's thread | an item on the resolver's own queue |
| `Semaphore.acquireStep` (`Task/Sync.lean`) | the waiter's route, from the releasing step | the resolvers' own queue |
| `Channel.sendStep` (`Task/Sync.lean`) | the sender's route, from the receiving step | the resolvers' own queue |
| `Channel.recvStep` (`Task/Sync.lean`) | the receiver's route, from the sending step | the resolvers' own queue |
| `HarnessClock.clock`'s scheduled fire (`Runtime/Clock.lean`) | the sleeper's route, from the advancing thread | the **shared** route: an expiry is an event, not a step's own re-enqueue |

The rule those sites are the reason for has **two halves**. A *step's own re-enqueue* takes the route of the
worker that fires it — `Ctx.resume`, the worker's own queue — which is the model's `pushLocal` premise
(`docs/interface.md`'s obligation table) and every push into a worker's own queue is owner-made because of it.
Every resume that is **not** a step's own — a leaf completion, a blocking completion, a harness-clock fire, a
resolution made by a thread that owns no queue — takes the **shared** route (`Ctx.resumeShared`, the inject),
whose push unparks a parked waiter under the shared cell's own lock. The shared-by-design set is therefore the
two seam completions (`Runtime/Leaf.lean`'s leaf continuations and `Runtime/Blocking.lean`'s blocking
completion), the harness clock's fire (`Runtime/Clock.lean`), `Runtime.Handle.spawn`, and the root pushes of
`Runtime.run`/`runWith`/`runCarriers`. `Runtime.spawn` and the child a step starts (`Async.spawn`) push on the
*spawning* worker's own route, which that worker is running when it makes the push.
-/

namespace LeanIn.Task

/-- **A computation's cancellation token.** One flag, with the two operations a cancellation needs: `set`, which
is what requesting one does, and `isSet`, which is what a step asks before running.

The id is here so that a question can be asked *about one computation* — how many registrations it still holds —
rather than about the runtime, whose total includes every other computation's and is not stable at the moment of a
read. `BaseIO` and not `IO` for the flag, because the read happens on a step's path and scheduling is `BaseIO`;
idempotent, because a cancellation is a request rather than a state transition, so a second one is not a defect. -/
structure Cancel where
  flag : IO.Ref Bool
  id : Nat

namespace Cancel

/-- The token allocator, module-level because a token is made wherever a computation is spawned, by code that owns
no runtime. The read and the write are one critical section under the counter's own lock, so two spawns running
concurrently — one on a carrier, one off it, as a `Runtime.Handle` lets a plain thread do — cannot both read the
same `n` and hand out the same id. That matters because an id is how a question is asked *about one computation*
(`Hooks.pendingFor` attributes a registration by it, and a retire reads it): two live tokens sharing an id would
make that answer wrong. An id only has to distinguish the tokens alive at one moment. -/
initialize counter : Std.Mutex Nat ← Std.Mutex.new 0

def new : IO Cancel := do
  let n ← counter.atomically do
    let n ← get
    set (n + 1)
    return n
  return ⟨← IO.mkRef false, n⟩

def set (c : Cancel) : BaseIO Unit := c.flag.set true

def isSet (c : Cancel) : BaseIO Bool := c.flag.get

end Cancel

/-- **One unit of scheduled work**: a step of some computation, ready to run. Named rather than a bare
`IO Unit` so that the executor's item type has an `Inhabited` instance, which the pool's ghost view needs.

A step's re-enqueue route is **not** carried: the worker that fires a step supplies its own route, through the
`Ctx` the runtime builds at fire time, so a computation's children follow the worker that ran the parent. The
route travels as an **index** rather than as a function: `act : (Item → BaseIO Unit) → IO Unit` is a
non-positive occurrence of `Item`, which Lean's kernel refuses, and no wrapper helps because the checker
unfolds definitions — but `Nat → IO Unit` is positive, so the action takes the firing worker's index and reads
the route from it. A *root* builds `Item.ofIndexed`, whose action supplies the firing worker's own route, and a
continuation another worker delivers is `Item.ofDeferred`, whose action re-binds the waiting computation's
context at the index it is fired with. Only `Item.ofAction`, whose action ignores the index, keeps a step
whose fire never re-routes it. -/
structure Item where
  /-- The token of the computation this step belongs to, or `none` for a step no cancellation reaches — the
  driver's, or one submitted straight to an executor. -/
  cancel : Option Cancel
  /-- One firing of this step, with the index of the worker that fires it. -/
  act : Nat → IO Unit

instance : Inhabited Item := ⟨⟨none, fun _ => pure ()⟩⟩

/-- **This step, stamped with a token if it does not have one.**

A step built inside a computation is bare, so the first stamping function it meets is its own computation's, and
the ones it meets afterwards leave it alone. That ordering is what gives the identities: an item a computation
enqueues belongs to that computation, and an item it hands to its parent's function keeps the inner token. -/
def Item.stamp (it : Item) (c : Cancel) : Item :=
  match it.cancel with
  | some _ => it
  | none   => { it with cancel := some c }

/-- **A step whose action ignores the firing worker's index**, for a step that needs no route: a caller's own
cost measurement, or a step that carries everything it uses. A continuation another worker delivers cannot use
this shape — it uses `Item.ofDeferred`, whose action reads the route at the index it is fired with. -/
def Item.ofAction (act : IO Unit) : Item := ⟨none, fun _ => act⟩

/-- **A step whose action receives the firing worker's index** — the shape a root builds, so the computation
it starts reads the firing worker's route and its children follow the worker that ran the parent. -/
def Item.ofIndexed (cancel : Option Cancel) (f : Nat → IO Unit) : Item := ⟨cancel, f⟩

/-- **Whether this step is cancelled.** -/
def Item.cancelled (it : Item) : IO Bool :=
  match it.cancel with
  | some c => c.isSet
  | none   => return false

/-- **Run a step on a carrier with index `i`.** The check is here, at the one place every carrier runs a
step through, so a cancelled computation's steps are skipped whether they were enqueued before the
cancellation or after it — the difference between this and a flag the computation itself has to poll.
Skipping is not running a no-op: nothing of the computation executes. The index is the firing worker's, and
it is what an `ofIndexed` root reads its route from. -/
def Item.fireWith (it : Item) (i : Nat) : IO Unit := do
  unless ← it.cancelled do it.act i

/-- **Run a step on the driver's worker.** The index is worker `0`'s, the calling thread the driver runs on. -/
def Item.fire (it : Item) : IO Unit := it.fireWith 0

/-- **What a computation carries ambiently, and its children inherit.** A request id, a deadline and a tracing
context — the values a log line or a deadline check reads without every signature between them gaining a
parameter. Nothing in the task layer or the runtime reads these fields: the runtime schedules, and a caller's log
line or a caller's deadline check reads them.

A typed record rather than a heterogeneous store keyed by name: a reader and a writer of a key agree by type
rather than by convention, and the value is one immutable copy a child takes at its spawn site rather than a map
behind a second lock. -/
structure Local where
  /-- The request this computation belongs to, or zero for none. -/
  requestId : Nat := 0
  /-- An absolute monotonic-nanosecond instant, or none. Nothing here reads it; W13's clock decides it. -/
  deadline : Option Nat := none
  /-- A tracing context: the one string a log line quotes. -/
  trace : String := ""

/-- **What a step is given**: its own cancellation token, and how to schedule an item — never a route that was
resolved before the step ran.

`resume` is the **local** route of the worker firing this step: that worker's own queue, which only that worker
may push into — the model's `pushLocal` premise (`docs/interface.md`'s obligation table). `routeAt` is the
runtime's route *table* — `routeAt n` is worker `n`'s own queue — and it is why a context is not a route: a
continuation another worker resolves is delivered as an item whose action reads the table at the index it is
*fired* with (`Item.ofDeferred`, `Ctx.rebind`), so a step's re-enqueue takes the route of the worker that fires
it and no continuation holds a route that was resolved before it ran.

`resumeShared` is the **shared** route — the inject, whose push unparks a waiter — for a delivery made from a
thread that is not the owning carrier: the two seam completions (`Runtime/Leaf.lean`'s leaf continuations and
`Runtime/Blocking.lean`'s blocking completion), each of which runs on whichever thread completed the leaf or
job. `«local»` is the ambient context, inherited by a spawned child from its parent.

Both travel together and mean the same thing — the computation is what a cancellation stops and what a
registration belongs to — so they are one parameter rather than two. The token being a *field* here is what lets a
leaf await attribute its registration to the computation that is waiting, which is the difference between a
registry that can be retired and one that can only grow.

No field has a default, so every construction site states all of them and the route rule is a reviewed line
rather than a silent omission. -/
structure Ctx where
  /-- The token of the computation this step belongs to. -/
  cancel : Cancel
  /-- The local route of the worker firing this step: that worker's own queue. **Owner-only.** -/
  resume : Item → BaseIO Unit
  /-- The runtime's route table: `routeAt n` is worker `n`'s own queue. A continuation deferred to another
  worker reads its route here, at the index it is fired with. -/
  routeAt : Nat → Item → BaseIO Unit
  /-- The **shared** route: the inject, whose push unparks a waiter. Every delivery made from a thread that is
  not the owning carrier takes this route — the two seam completions above. -/
  resumeShared : Item → BaseIO Unit
  /-- The ambient context, inherited by a spawned child from its parent. -/
  «local» : Local

/-- **The context a step runs under when worker `i` fires it**: that worker's own route as the local route, the
runtime's route table beside it, and the computation's token and ambient context. The one place the invariant
`resume = routeAt i` is stated for a runtime-built context. -/
def Ctx.at (cancel : Cancel) (table : Nat → Item → BaseIO Unit) (shared : Item → BaseIO Unit)
    (l : Local) (i : Nat) : Ctx :=
  { cancel := cancel, resume := table i, routeAt := table, resumeShared := shared, «local» := l }

/-- **The same context, with the local route read for the worker that fires the step about to run.** This is
what makes a route fire-time: the context travels — its token, its ambient context and the route table travel
with it — and the route is read here, at the index the item is fired with. -/
def Ctx.rebind (c : Ctx) (i : Nat) : Ctx := { c with resume := c.routeAt i }

/-- **A continuation delivered to whichever worker fires it**: the waiting computation's token, and an action
whose context is re-bound at the firing index. The token is the *waiter's* and only the route is the *firer's*
— the distinction `Sync`'s retries turn on, so a retry keeps its own stamp. -/
def Item.ofDeferred (c : Ctx) (act : Ctx → IO Unit) : Item :=
  ⟨some c.cancel, fun i => act (c.rebind i)⟩

namespace Join

/-- **A waiter**: the waiting computation's context — its token and its ambient context, which the delivery
keeps — and what to run when the value arrives, under the context of the worker that runs it. -/
structure Waiter (α : Type) where
  /-- The context of the computation that registered. -/
  ctx : Ctx
  /-- The continuation, run under the context of the worker that fires it. -/
  run : α → Ctx → IO Unit

end Join

/-- **The join cell**: what a handle is. The value once there is one, and the continuations left by whoever
awaited it before then.

One lock, because the resolver and the awaiter can be different threads — and here they usually are: the
resolver is whoever finished the task, the awaiter is a carrier that yielded. -/
structure Join (α : Type) where
  lock : Std.Mutex (Option α × List (Join.Waiter α))

def Join.new : IO (Join α) := return ⟨← Std.Mutex.new (none, [])⟩

/-- **A cell that already holds its value.** Nothing can have registered on it — a waiter exists only after the
cell is handed out — so there is no delivery and no route to state: the value is put in at the construction
rather than by a resolution. -/
def Join.resolved (v : α) : IO (Join α) := return ⟨← Std.Mutex.new (some v, [])⟩

/-- **Deliver one waiter as an item on `push`.**

`push` is the *resolving* step's own route — its own queue when the resolver is a carrier, the shared list when
it is a thread that owns no queue — so the push is owner-made. What is enqueued is the waiter's continuation,
with its context re-bound at the firing index: the route comes from the firer and the token from the waiter. -/
private def Join.deliver (push : Item → BaseIO Unit) (w : Join.Waiter α) (v : α) : BaseIO Unit :=
  push (Item.ofDeferred w.ctx (fun ctx => w.run v ctx))

/-- **Resolve**, delivering whoever was waiting as an item on `push`.

Inside the lock the value goes in and the waiting waiters come out; outside it they are delivered. A delivery
inside would mean enqueuing — which takes the executor's lock, or borrows a worker's own queue — while holding
this one, and two locks in one path is how a runtime acquires a lock order nobody chose.

Resolving twice is a defect rather than a race to be tolerated, so it is loud: a handle is resolved by the one
computation that owns it, exactly once, and a second resolution means two writers. -/
def Join.resolve (j : Join α) (push : Item → BaseIO Unit) (v : α) : IO Unit := do
  let ws ← j.lock.atomically do
    let st ← get
    match st.1 with
    | some _ => throw (IO.userError "Join.resolve: a task was resolved twice")
    | none   => set (some v, ([] : List (Join.Waiter α))); return st.2
  for w in ws do Join.deliver push w v

/-- **Resolve unless it is already resolved**: the first writer wins and a later one is *ignored* rather than a
defect.

Separate from `resolve` on purpose, and the difference is a law rather than a convenience. `resolve` states
that a handle has one writer, and is loud when that is broken; this states that several writers may race and
the result is the first of them, which is what a timeout or a `select`-shaped operation needs and what a
computation which is simply finishing normally must not rely on. -/
def Join.resolveFirst (j : Join α) (push : Item → BaseIO Unit) (v : α) : IO Unit := do
  let ws? ← j.lock.atomically do
    let st ← get
    match st.1 with
    | some _ => return none
    | none   => set (some v, ([] : List (Join.Waiter α))); return some st.2
  match ws? with
  | some ws => for w in ws do Join.deliver push w v
  | none    => pure ()

/-- **Register, or run now.** An awaiter that arrives after the value did must not be left waiting: it runs
immediately under its own context — the same worker's step, so nothing is deferred and no route is needed. That
is also what makes awaiting a finished handle return at once instead of yielding. -/
def Join.onReady (j : Join α) (ctx : Ctx) (k : α → Ctx → IO Unit) : IO Unit := do
  let now? ← j.lock.atomically do
    let st ← get
    match st.1 with
    | some v => return some v
    | none   => set (st.1, st.2 ++ [{ ctx := ctx, run := k }]); return none
  match now? with
  | some v => k v ctx
  | none   => pure ()

/-- **A scheduleable computation.**

`step k ctx` runs the computation until it finishes — calling `k` with the value and with the context the
continuation runs under, which is the context of the worker that fired the step that finished — or until it must
wait, in which case it registers a continuation and returns. `bind` composes the continuations, so a resumed
computation continues from where it yielded rather than from its beginning — the difference between this and a
bare `Job`, which is a value that must be re-run.

The continuation takes the context because the step that calls it may be a *different worker's*: a continuation
another worker delivers is an item whose context is re-bound at the firing index (`Item.ofDeferred`), and the
rest of the computation must re-enqueue on that worker's route rather than on the one the waiting step held.

The scheduling half of `ctx` is `BaseIO` rather than `IO`, and that is the O3 seam showing through: the one place a
schedule call has to happen is *inside a waker* — a continuation registered on a stock `Task`, running on a pool
worker — and a waker cannot call `IO`. Enqueuing takes a lock and notifies a condvar, so `BaseIO` is all it needs,
and the runtime's `Ctx.resume`/`Ctx.resumeShared` are those two functions — the local route for an owner-made
push, the shared route for a push from a thread that is not the owning carrier. -/
structure Async (α : Type) where
  step : (α → Ctx → IO Unit) → Ctx → IO Unit

instance : Inhabited (Async α) := ⟨⟨fun _ _ => pure ()⟩⟩

instance : Monad Async where
  pure v   := ⟨fun k ctx => k v ctx⟩
  bind a f := ⟨fun k ctx => a.step (fun v ctx' => (f v).step k ctx') ctx⟩

/-- Run an `IO` action as a step of a computation. This is the inside of `interface.md` §4's one bridge: a leaf
operation — a timer, a socket, a stock `Task` — arrives as an action, and what keeps it non-blocking is that
whoever completes it schedules the continuation instead of running it here. -/
def Async.ofIO (act : IO α) : Async α := ⟨fun k ctx => do k (← act) ctx⟩

instance : MonadLift IO Async where monadLift act := Async.ofIO act

/-- **Read the ambient context.** A field read of the immutable `Ctx` the step was already given — no lock, no
lookup, and no signature between the reader and its caller gains a parameter. -/
def Async.«local» : Async Local := ⟨fun k ctx => k ctx.«local» ctx⟩

/-- **The local route of the step being run**, for a step that has to deliver: a resolution (`Join.resolve`,
`Task.cancel`) and a sync release or probe that hands a wake to a parked waiter all take the *delivering* step's
own route, and this is where a step running inside a computation gets it. The route is read here, at the step
that is running, never captured earlier. -/
def Async.push : Async (Item → BaseIO Unit) := ⟨fun k ctx => k ctx.resume ctx⟩

/-- **Run a computation under a local context.** The value is installed on the `Ctx` this computation's steps run
with, and restored for the continuation: a `spawn` inside it therefore builds the child's `Ctx` from a parent
that already carries it, which is how the child inherits the innermost enclosing value at its spawn site, while
the enclosing value is what the rest of this computation reads again. -/
def Async.withLocal (l : Local) (a : Async α) : Async α :=
  ⟨fun k ctx => a.step (fun v ctx' => k v { ctx' with «local» := ctx.«local» }) { ctx with «local» := l }⟩

/-- **A handle** on a spawned computation: the cell its value lands in, and its cancellation token. -/
structure Task (α : Type) where
  cell : Join α
  /-- Set by `Task.cancel`. Every step of this computation reads it before running, and every registration the
  computation leaves behind is attributed to it. -/
  token : Cancel

/-- **Cancel a handle's computation**: its token is set, so `Item.fire` skips its steps from now on, and its cell
is resolved with `v` through `resolveFirst`.

`resolveFirst` is the law for this race rather than `resolve`: `resolve` states that a handle has one writer and is
loud when that is broken, while here a computation finishing and a cancellation arriving genuinely race, and the
first of them is the result. So a computation that has already produced its value keeps it — a cancellation never
replaces a value that exists — and a cancellation that arrives first is delivered exactly once and immediately,
rather than leaving an awaiter parked forever on a value that will never come.

`push` is the **cancelling step's own route** — `Async.ctx`'s `resume` — because a resolution delivers the cell's
waiters as items on the resolving step's queue: the route comes from the firer and the token from the waiter, so a
cancelled awaiter's continuation runs on the worker that cancelled, not on the one the waiter came from.

`v` is the caller's because this layer has no error of its own to give: `EAsync`'s handles are `Task (Except ε α)`,
so a server passes `.error (.userError "…")`.

Retiring the computation's registrations is not here but in the runtime, which is where the registry is. -/
def Task.cancel (t : Task α) (push : Item → BaseIO Unit) (v : α) : IO Unit := do
  t.token.set
  Join.resolveFirst t.cell push v

/-- **Start a computation on the current worker.** The child's first step is enqueued through the *parent's* local
route, which the parent is running on, so that push is owner-made; and the child's own context is built **at fire
time**, by the item's action: what travels is the parent's route *table*, so the worker that fires the child's
first step supplies the routes the child's steps re-enqueue on. A chain of spawns therefore follows the worker
that ran each parent rather than the worker that created it.

Only the token is fresh and the ambient context inherited: `cancel` is the child's own, and `«local»` is the
parent's, the innermost enclosing value at this spawn site. Cancelling the parent therefore does not stop the
child, whether it has started or not: every spawned computation is cancellable on its own, which is `abort`
rather than structured cancellation. A computation that wants its children to stop with it has to cancel them. -/
def Async.spawn (a : Async α) : Async (Task α) := ⟨fun k ctx => do
  let cell ← Join.new
  let cancel ← Cancel.new
  ctx.resume (Item.ofIndexed (some cancel) (fun i =>
    a.step (fun v ctx' => Join.resolve cell ctx'.resume v)
           { ctx.rebind i with cancel := cancel }))
  k ⟨cell, cancel⟩ ctx⟩

/-- **The value, if it is already there.** -/
def Join.value? (j : Join α) : IO (Option α) := j.lock.atomically do return (← get).1

/-- **Await.** If the value is already there, `k` is called now and the step does not yield: awaiting a
finished handle costs a lock and no scheduling round, which is what a `JoinHandle` polled as ready does.
Otherwise the continuation left behind is **delivered as an item** when the value arrives — on the queue of the
worker that resolves the cell (`Join.onReady`, `Join.resolve`) — carrying this computation's token and ambient
context and reading *that* worker's route, and `step` returns without calling `k`.

That is the site the per-worker wake flag used to stand in for: the continuation used to close over the
*awaiting* step's route and be run on the *resolver's* thread, which is a push into a queue whose owner may be
parked. Delivering an item on the resolver's own queue makes the push owner-made and the wake unnecessary.

Reading then registering is not a race: if the value arrives between the two, `onReady` runs the continuation
immediately, which is the case it exists for. -/
def Async.await (t : Task α) : Async α := ⟨fun k ctx => do
  match ← t.cell.value? with
  | some v => k v ctx
  | none   => Join.onReady t.cell ctx k⟩

/-- **The first of several handles to become ready.**

Homogeneous and non-empty: `h` is the head, so index `0` names it and index `i+1` names `hs[i]`; a zero-handle
`select` is unrepresentable rather than a meaningless `none`. It returns the winner's index into the list as
given and its value, and it does not cancel its losers — a handle passed to `select` is still awaitable
elsewhere.

Among handles already resolved when `select` is reached, the earliest in list order wins; among handles resolved
while `select` waits, the first resolution wins.

Each per-handle registration resolves this `select`'s own cell with the *resolver's* route (`ctx'.resume`), so a
winner's continuation is delivered on the worker that resolved it, and this step's own parking follows
`Async.await`'s rule. -/
def select (h : Task α) (hs : List (Task α)) : Async (Nat × α) := ⟨fun k ctx => do
  let j ← (Join.new : IO (Join (Nat × α)))
  -- One registration per handle, each carrying its index. `Join.onReady` runs a continuation immediately when
  -- the handle is already resolved, so an already-satisfiable `select` resolves `j` during this loop, in list
  -- order — the tie rule for handles resolved before the call.
  let rec go : List (Task α) → Nat → IO Unit
    | [], _ => pure ()
    | t :: ts, i => do
        Join.onReady t.cell ctx (fun v ctx' => Join.resolveFirst j ctx'.resume (i, v))
        go ts (i + 1)
  go (h :: hs) 0
  -- Mirror `Async.await`: a value already in the shared cell (a handle resolved during the loop) is returned
  -- in-step with no scheduling round; otherwise the step parks on the shared cell.
  match ← Join.value? j with
  | some w => k w ctx
  | none   => Join.onReady j ctx k⟩

/-- **Wait for every handle, in list order.** `join [] = pure []`, and the pair case stays `concurrently`. -/
def join (hs : List (Task α)) : Async (List α) := hs.mapM Async.await

/-- **What generic code is written against**: joining and starting, with the handle type alongside. -/
class MonadAwait (m : Type → Type) where
  /-- The handle type: what starting a computation in `m` gives you. -/
  Handle : Type → Type
  /-- Wait for a handle's value. -/
  await : Handle α → m α

/-- Anything that can also start computations. -/
class MonadAsync (m : Type → Type) extends MonadAwait m where
  /-- Start a computation on the current worker. -/
  spawn : m α → m (Handle α)

instance : MonadAwait Async where
  Handle := Task
  await  := Async.await

instance : MonadAsync Async where
  spawn := Async.spawn

/-- Run both and return both values. Concurrent in the sense that matters: both are scheduled before either is
awaited. Written once, against the class, so any implementation of it gets this for free. -/
def concurrently [Monad m] [MonadAsync m] (a b : m α) : m (α × α) := do
  let ha ← MonadAsync.spawn a
  let hb ← MonadAsync.spawn b
  let va ← MonadAwait.await ha
  let vb ← MonadAwait.await hb
  return (va, vb)

/-- Run it and drop the handle: still scheduled, nothing waits for it. -/
def background [Monad m] [MonadAsync m] (a : m α) : m Unit := do
  let _ ← MonadAsync.spawn a
  return ()

end LeanIn.Task
