import Std
import LeanIn.Task.Send

/-!
# The runtime: P carriers, and the driver on the calling thread

`interface.md` §3's `blockOn` and §4's task layer wired to `Sched.Executor`: the executor holds `Item`s, and
this file is what decides *where* they run.

**One loop, used twice.** `Runtime.startCarriers e p` runs `Executor.workerLoop` on `p` dedicated threads; the
driver (`run`/`runWith`/`blockOn`) runs worker `0`'s loop **on the calling thread**, through the same
operations. That is why no existing scenario's driver changed: a single-carrier run is worker `0`, and the
instrument it uses is the one a carrier uses.

**Routes.** A computation's re-enqueue route is not captured at its spawn site any more: the *worker that
fires a step* supplies its own route, so a computation's children follow the worker that ran the parent —
`docs/interface.md` §3's rule ("a chain stays on the core its parent ran on") now stated at P carriers. The
root of a chain is submitted to the **shared list** (`Executor.pushInject`), because no worker owns it, and
the item it builds is `Item.ofRouted`: its body receives the firing worker's route instead of a captured one.

**What crosses a carrier boundary.** Every push into a carrier's queue goes through `Task.Send.lean`'s marker
(`Executor.pushInject`/`spawnLocal`/`submitLocal`, all of which take a `Sendable`), so the values that cross
are the ones this library built. `Handle` is the capability an off-carrier thread gets; a spawn through it
goes to the shared list, which is what a thread that is not a carrier can reach.

No worker threads beyond `startCarriers`, no pool: an item is taken and run on the thread that took it, and
`Executor.takeFor` parks that thread when there is nothing to take — which is exactly why a completion
arriving from another thread may only *enqueue*.
-/

namespace LeanIn.Runtime

/-- The runtime's executor: it holds task steps. -/
abbrev Executor (cap : Nat) := Sched.Executor Task.Item cap

/-- **Where a spawn asks the executor to place the task's first step.** `.high` is the owner-local one-slot LIFO
buffer, served before the ring while the tick's allowance lasts; `.normal` is the FIFO ring. It is a placement
request and promises nothing about *when* the task runs. -/
inductive Priority where
  | high
  | normal

/-- **The fire entry for an `ofIndexed` root**: run computation `a` on the worker whose index is `i`, with
that worker's own routes on the `Ctx`.

The local route is the *firing* worker's (`Executor.route e i`), so a child a step spawns follows the worker
that ran the parent — `docs/interface.md` §3's rule at P carriers — and the shared route is the inject, for
the seam continuations that run on a thread which is not the owning carrier. `done` is the computation's
finish. -/
def fired (cancel : Task.Cancel) (e : Executor cap) (a : Task.Async α) (done : α → IO Unit)
    (i : Nat) : IO Unit :=
  let ctx : Task.Ctx :=
    { cancel       := cancel
    , resume       := (e.route i).enqueue
    , resumeShared := fun it => e.pushInject (Task.Item.sendable it)
    , «local»      := {} }
  a.step done ctx

/-- **Spawn from the calling thread**: the placement `prio` asks for, on worker `0` — `.high` puts the step in
the LIFO slot and `.normal` in the ring — so the lane keeps the mechanism `SC16` asserts. A `.high` task is
served sooner, never promised to run. -/
def spawn (e : Executor cap) (prio : Priority) (a : Task.Async α) : IO (Task.Task α) := do
  let cell ← Task.Join.new
  let cancel ← Task.Cancel.new
  let it := Task.Item.ofIndexed (some cancel) (fired cancel e a (fun v => Task.Join.resolve cell v))
  match prio with
  | .high   => e.spawnLocal 0 (Task.Item.sendable it)
  | .normal => e.submitLocal 0 (Task.Item.sendable it)
  return ⟨cell, cancel⟩

/-- **The counters a handle reports.**

`ready` and `parked` are the composition's own two numbers, read through `Executor.observe` — every worker's
own queue plus the shared list, and the parked count out of the shared cell — so a counter cannot disagree
with the composition about what the executor holds. `carriers` is per carrier, index `i` for worker `i`, and
`some` only for an executor built metered. -/
structure Metrics where
  /-- Work ready to be taken: every worker's own queue plus the shared list. -/
  ready    : Nat
  /-- Waiters parked now: carriers and the calling-thread driver, each wait having recorded itself. -/
  parked   : Nat
  /-- Per-carrier counters, `some` only for a metered executor. -/
  carriers : Option (List Sched.CarrierCounters)
deriving Repr

/-- **The capability handed to a thread that is not a carrier.**

It holds the executor and exposes exactly three operations — `spawn`, `stop`, `metrics` — and the withheld half
is the point: `Executor.workerLoop`, `Executor.park`, `Executor.takeFor`, `Executor.snapshot` and every
`Hooks` operation are carrier-side and are not reachable from here.

What makes it usable off-carrier is that every shared cell those three operations reach is read and written
inside that cell's own lock, so their critical sections are serializable against a carrier's; and a spawn from
a parked-against thread cannot be lost, because the push's unpark is issued inside the same lock the parking
predicate is re-checked under. That is an argument, not a theorem — it needs the serializability lemma
`docs/primitive-theory.md` §4 states as unproved — and it is not a `Send` marker: it fixes one object by
audit and checks nothing a caller shares with a thread. -/
structure Handle (α : Type) (cap : Nat) where
  private mk ::
    /-- The executor the handle holds. Both this field and the constructor are **private**, so the three
    operations below are the whole surface rather than a convention: a caller holding a `Handle` can neither
    project the executor out nor build one, and so cannot reach the carrier-side operations — the loop, the
    park, the take, the snapshot — that the handle exists to withhold. -/
    private e : Sched.Executor α cap

/-- The handle for an executor. -/
def handle (e : Sched.Executor α cap) [Inhabited α] : Handle α cap := ⟨e⟩

/-- **Spawn from a thread that is not a carrier.** The handle must be one over a task executor — the runtime's
only executor, whose items are steps — because the child's first step is what it enqueues; the item it builds
carries the child's completion cell and the child's token, and its route is supplied by whichever carrier fires
it. The step goes to the **shared list**, which is the one queue an off-carrier thread can reach; `prio` is
therefore a request the firing worker's own route honours, not a choice this call can make. -/
def Handle.spawn (h : Handle Task.Item cap) (_prio : Priority) (a : Task.Async α) : IO (Task.Task α) := do
  let cell ← Task.Join.new
  let cancel ← Task.Cancel.new
  let it := Task.Item.ofIndexed (some cancel) (fired cancel h.e a (fun v => Task.Join.resolve cell v))
  h.e.pushInject (Task.Item.sendable it)
  return ⟨cell, cancel⟩

/-- Stop the executor: `Executor.stop`, so a later iteration of a serving loop sees the flag. -/
def Handle.stop (h : Handle α cap) [Inhabited α] : IO Unit := h.e.stop

/-- The two counts and the per-carrier counters, read without mutating or notifying anything. -/
def Handle.metrics (h : Handle α cap) [Inhabited α] : IO Metrics := do
  let (ready, parked) ← h.e.observe
  let carriers ← h.e.metrics
  return { ready, parked, carriers }

/-- The handle's own carrier count, for a client that reads the composition rather than the counters. -/
def Handle.workerCount (h : Handle α cap) [Inhabited α] : Nat := h.e.workerCount

/-- **The carriers, as a capability**: the executor they run on, the threads themselves, and the thread ids
they recorded as they started.

The fields are private and the constructor with them, so a caller can stop, join and read the carriers but
cannot reach the carrier-side operations on them. -/
structure Carriers (cap : Nat) where
  private mk ::
    private e       : Executor cap
    private threads : Array (_root_.Task (Except IO.Error Unit))
    private ids     : Std.Mutex (List UInt64)

/-- **Start `p` carriers for worker indices beginning at `first`** — `first`, `first + 1`, …, `first + p - 1`.
Each is a dedicated thread running `Executor.workerLoop` on the index it was given, with the runtime's fire
function: the step runs on the worker's own route, so a chain stays where its parent ran. The thread records
its id before entering the loop, which is what makes "which carriers were started" readable without the client
keeping a log. -/
private def startCarriersFrom (e : Executor cap) (first p : Nat) : IO (Carriers cap) := do
  let tids ← Std.Mutex.new ([] : List UInt64)
  let mut ts : Array (_root_.Task (Except IO.Error Unit)) := #[]
  for i in List.range p do
    let t ← IO.asTask (do
        tids.atomically do set ((← get) ++ [← IO.getTID])
        e.workerLoop (fun idx it => it.fireWith idx) (first + i)) _root_.Task.Priority.dedicated
    ts := ts.push t
  return ⟨e, ts, tids⟩

/-- **Start `p` carriers**, one for each of worker indices `0 … p - 1`. -/
def startCarriers (e : Executor cap) (p : Nat) : IO (Carriers cap) :=
  startCarriersFrom e 0 p

/-- Stop the carriers: the flag, and every parked carrier woken. A stop is a drain rather than a cut — a
worker's loop leaves only when the flag is set and it has nothing left to take. -/
def Carriers.stop (c : Carriers cap) : IO Unit := c.e.stop

/-- Wait for every carrier thread to exit. A worker that never returns makes this wait unbounded, which is
stated rather than promised away — `BlockingPool.shutdownAndWait`'s existing wording. -/
def Carriers.join (c : Carriers cap) : IO Unit := do
  for t in c.threads do
    match ← IO.wait t with
    | .ok _    => pure ()
    | .error _ => pure ()

/-- How many carriers this capability started. -/
def Carriers.count (c : Carriers cap) : Nat := c.threads.size

/-- The thread ids the carriers recorded as they started. -/
def Carriers.tids (c : Carriers cap) : IO (List UInt64) :=
  c.ids.atomically do return (← get)

/-- The carriers' metrics, read through the shared cell and the per-carrier counters. -/
def Carriers.metrics (c : Carriers cap) : IO Metrics := (handle c.e).metrics

/-- **An executor that accumulates per-carrier counters.** `Executor.new` leaves metering off, so the default
item path pays one test and neither a lock nor a clock read; this is the configuration the cost rows measure. -/
def Executor.newMetered (cap workers : Nat) : IO (Executor cap) :=
  Sched.Executor.newMetered Task.Item cap workers

/-- Run one item on the driver's own thread, reading the driver's clock around it when the executor is
metered and never otherwise. -/
private def fireAt (e : Executor cap) (now : IO Nat) (it : Task.Item) : IO Unit := do
  if e.isMetered then
    let t0 ← now
    it.fire
    let t1 ← now
    e.accrueAt 0 (t1 - t0)
  else it.fire

/-- **Drive worker `0`'s loop on the caller's thread** until `finished` holds, with a hook for a driver that
has somewhere to advance to.

This is the single-carrier claim as code: there is no other thread to hand the wait to, so the caller runs the
item itself and parks in `Executor.workWith` when nothing is ready. That park is the protocol's — the
predicate is re-checked under the same lock a push notifies under — so a completion arriving while this thread
is parked wakes it rather than being lost.

`idle` reaches `Executor.workWith`, which asks it only when the queue is empty while the executor still runs,
so a driver with nothing to advance to behaves exactly as before. `now` is read around each item's run when
the executor is metered, and never otherwise. -/
def blockOnWith (e : Executor cap) (now : IO Nat) (idle : IO Bool) (finished : IO Bool) : IO Unit := do
  let mut go := true
  while go do
    if ← finished then go := false
    else
      match ← e.workWith idle with
      | some it => fireAt e now it
      | none    =>
        -- The queue is empty *and* the executor is stopping, which for a worker is the end of its shift and
        -- for the driver is not the end of anything. A stopped executor can still hold work in the form of
        -- continuations registered on leaves — those are not in a queue by construction, because an awaited
        -- leaf yields and enqueues nothing — so ending the driver here abandons them, and every task waiting
        -- on one hangs forever.
        --
        -- Waiting instead is the drain the model's shutdown states ("set `stopping`, notify all, drain"): a
        -- completion arrives through a route, which enqueues and notifies, so the wait wakes with work to
        -- take or with the value the caller is waiting for. The bound on a drain that cannot finish is a
        -- deadline, which is the caller's to impose and W7's to make cheap.
        e.waitForWork

/-- **Drive worker `0`'s loop on the caller's thread** until `finished` holds.

`blockOnWith` with a hook that reports nothing and a clock that is never read — the driver `Runtime.run` uses,
and the one every existing scenario runs through. -/
def blockOn (e : Executor cap) (finished : IO Bool) : IO Unit :=
  blockOnWith e IO.monoNanosNow (do return false) finished

/-- Run one computation to completion on the caller's thread and return its value, driving it with `now` and
`idle`: `idle` is the driver's own step when nothing in the queues can run, which is where a virtual clock
advances.

The computation's first step goes to the **shared list**, because no worker owns the root of a chain; the
worker that takes it supplies the route its children follow. The completion is a cell the computation's own
last step writes, so the driver's stop condition is the value arriving rather than a clock or a count. If the
driver stops for another reason — the executor stopping — the missing value is reported rather than filled in
with a default. -/
def runWith (e : Executor cap) (now : IO Nat) (idle : IO Bool) (a : Task.Async α) : IO α := do
  -- **The completion cell is lock-guarded, and the completion records itself in the cell the driver waits on.**
  -- The program's last step may run on a carrier while the driver is parked on the calling thread, so the value
  -- cell is cross-thread state (D8) and a plain `IO.Ref` would be a violation; and a driver parked on the
  -- shared cell cannot be reached by a carrier that only finishes the program, so `noteFinished` writes the
  -- stop condition and notifies in that cell's own section, which is the lock its predicate is evaluated under.
  let done ← Std.Mutex.new (none : Option α)
  e.clearFinished
  -- The driver's own computation carries no token and no handle: the driver is a caller's thread waiting, and
  -- the computation it drives is not one another task holds a handle to.
  let cancel ← Task.Cancel.new
  let finish : α → IO Unit := fun v => do
    done.atomically do set (some v)
    e.noteFinished
  let it := Task.Item.ofIndexed (some cancel) (fired cancel e a finish)
  e.pushInject (Task.Item.sendable it)
  blockOnWith e now idle (do return (← done.atomically do return (← get)).isSome)
  match ← done.atomically do return (← get) with
  | some v => return v
  | none   => throw (IO.userError "Runtime.run: the driver stopped before the computation finished")

/-- Run one computation to completion on the caller's thread and return its value: `runWith` with the live clock
reader and no idle step. -/
def run (e : Executor cap) (a : Task.Async α) : IO α :=
  runWith e IO.monoNanosNow (do return false) a

/-- **The parallel entry**: run a computation and return the dedicated carriers that were started alongside it,
so a caller can read what was started and stop it.

`p` dedicated carriers for workers `0 … p − 1` — `startCarriersFrom e 0 p` — with the computation's root on
the shared list, so any carrier may take it and each step's children follow the worker that ran their parent.
The caller **only waits** on the program's own cell: it does not run worker `0`'s loop, because worker `0`
already has a carrier thread, and a second thread on the same worker is not a wider driver but a second
consumer of one queue. The completion records itself in the cell the caller waits on (`noteFinished`), so a
program finished on a carrier ends the wait. -/
def runCarriers (e : Executor cap) (p : Nat) (a : Task.Async α) : IO (Carriers cap × α) := do
  let c ← startCarriersFrom e 0 p
  let done ← Std.Mutex.new (none : Option α)
  e.clearFinished
  let cancel ← Task.Cancel.new
  let finish : α → IO Unit := fun v => do
    done.atomically do set (some v)
    e.noteFinished
  let it := Task.Item.ofIndexed (some cancel) (fired cancel e a finish)
  e.pushInject (Task.Item.sendable it)
  e.waitFinished
  match ← done.atomically do return (← get) with
  | some v => return (c, v)
  | none   => throw (IO.userError "Runtime.runCarriers: the carriers stopped before the computation finished")

end LeanIn.Runtime
