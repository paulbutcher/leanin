module

public import Std
public import Std.Async.Timer
public import LeanIn.Runtime.Basic
public import LeanIn.Runtime.Leaf
public import LeanIn.Runtime.Io


public section
/-!
# The clock seam

The runtime's time enters as a parameter. `Clock` is a record of the two operations a computation needs from a
clock — a monotone reading in nanoseconds, and a one-shot wait — and `Runtime.sleep`/`Runtime.withTimeout` take
one. `Clock.live` is today's composition: `IO.monoNanosNow` for the reading, and the libuv timer behind W1's
seam for the wait, so the production path is the same code it always was, reached through a record instead of
directly.

The second implementation is the point of the seam. `HarnessClock` keeps a virtual instant and a sorted list of
pending timers under one mutex, and `HarnessClock.advance` moves the instant to the earliest deadline and fires
that timer. A driver that installs it decides one instant at a time: nothing is registered with libuv, so no
live clock is read anywhere on a harness run, and an instant is read as a number rather than waited out.

`runVirtual` is that driver: `Runtime.runWith`, the general entry, with this clock's reading and
`HarnessClock.advance` as the idle step. When nothing can be advanced to it parks exactly as the live driver
does, which is what keeps it composable with a leaf or with another thread's delivery — and means a mode that
awaits a gate nobody resolves hangs and is bounded by a watchdog rather than mis-reported as a wrong reading.

No production primitive is added here: `Clock.live` composes two things already on the register, and
`HarnessClock` calls no clock at all — its whole mechanism is one mutex over pure list and natural-number code.
-/

namespace LeanIn.Runtime

/-- **What a computation asks of a clock.** `now` is monotone nanoseconds; `sleep d` is a one-shot wait on
whichever clock is installed, awaited as one of ours so the waiter parks rather than occupies a carrier. -/
structure Clock where
  /-- The current instant, in monotone nanoseconds. -/
  now   : IO Nat
  /-- A one-shot wait for `d` from now. -/
  sleep : Std.Time.Millisecond.Offset → Task.Async Unit
  /-- **Arm a one-shot fire** after `d`, inert if `cancel` is set by then. Unlike `sleep` this runs a raw
  action rather than parking a waiter, so a timeout that resolves a cell directly leaves no parked task for a
  winner to abandon — `withTimeout` arms its deadline this way and sets the token when its computation wins. -/
  schedule : Std.Time.Millisecond.Offset → Task.Cancel → IO Unit → IO Unit
  /-- As `schedule`, with the continuation to run if the timer is retired without firing (a loop
  stop or a deadline): the sleeper is aborted rather than left parked. -/
  scheduleCancel : Std.Time.Millisecond.Offset → Task.Cancel → IO Unit → IO Unit → IO Unit
  /-- Whether a read's stall bound should be **swept** (the live clock: a slot the driver expires on its own
  timeout) or **armed** (a harness clock: an instant the driver advances to, retired exactly). -/
  swept : Bool

/-- **The production clock**: the live reading, and a `sleep` that parks the waiter and schedules its fire on
the runtime's own timing wheel (`Io.liveSchedule`). The wheel is driven by the loop thread that also services
socket completions, so a deadline ends the same park a socket does and no second thread services timers — the
stdlib's `Std.Async.sleep` keeps a loop thread of its own, and that thread is what a per-request deadline was
paying two context switches for. The step schedules the fire and returns without calling `k`, so the waiter
parks on its own cell; the fire, run by the loop thread, is inert if its token is set (a winning read cancels
the loser) and otherwise enqueues the waiter's continuation on the shared route, where a carrier runs it. -/
def Clock.live (_hooks : Hooks) : Clock :=
  { now   := IO.monoNanosNow
  , sleep := fun d => ⟨fun k ctx => do
      let fire : IO Unit := do
        unless ← Task.Cancel.isSet ctx.cancel do
          ctx.resumeShared (Task.Item.ofDeferred ctx (k ()))
      let now0 ← IO.monoNanosNow
      Io.liveSchedule (now0 + d.toInt.toNat * 1000000) ctx.cancel fire⟩
  , schedule := fun d cancel fire => do
      let now0 ← IO.monoNanosNow
      Io.liveSchedule (now0 + d.toInt.toNat * 1000000) cancel fire
  , scheduleCancel := fun d cancel fire onCancel => do
      let now0 ← IO.monoNanosNow
      Io.liveScheduleCancel (now0 + d.toInt.toNat * 1000000) cancel fire onCancel
  , swept := true }

/-- The virtual clock's state: the current instant and its pending timers, sorted by instant and FIFO on
ties. -/
structure HarnessState where
  /-- Virtual nanoseconds. -/
  now    : Nat := 0
  /-- The pending timers, earliest first. -/
  timers : List (Nat × IO Unit) := []
deriving Inhabited

/-- **A clock the harness drives.** Nothing registered with libuv: an instant is a number and a fire is a list
element. -/
structure HarnessClock where
  state : Std.Mutex HarnessState

/-- A harness clock at virtual instant zero with nothing pending. -/
def HarnessClock.new : IO HarnessClock :=
  return ⟨← Std.Mutex.new ({} : HarnessState)⟩

/-- The current virtual instant — the reading a scenario compares its stated instants against. -/
def HarnessClock.now (hc : HarnessClock) : IO Nat :=
  hc.state.atomically do return (← get).now

/-- How many timers are pending. -/
def HarnessClock.pending (hc : HarnessClock) : IO Nat :=
  hc.state.atomically do return (← get).timers.length

/-- **Schedule a fire at `instant`**, keeping the list sorted and FIFO among equal instants.

The insertion alone is not a wake. Unlike the live clock (`Io.liveSchedule`, whose `npUvWheelWake` ends the
loop pump's park), a harness instant lives in this list, not in libuv's wheel, and the thread that must reach
it is the *driver* — parked on the executor's condition variable. `HarnessClock.clockWithWake` is the
composition that supplies that wake; a caller using the bare `clock` arms instants that a driver already
parked will not see. -/
def HarnessClock.schedule (hc : HarnessClock) (instant : Nat) (fire : IO Unit) : BaseIO Unit :=
  hc.state.atomically do
    let s ← get
    let rec ins : List (Nat × IO Unit) → List (Nat × IO Unit)
      | []              => [(instant, fire)]
      | (t, f) :: rest  => if instant < t then (instant, fire) :: (t, f) :: rest else (t, f) :: ins rest
    set { s with timers := ins s.timers }

/-- **Advance to the earliest pending timer**: set the virtual instant to its `instant` and run its fire, outside
the lock. `false` when nothing is pending — the driver then parks as the live one does. -/
def HarnessClock.advance (hc : HarnessClock) : IO Bool := do
  let due ← hc.state.atomically do
    let s ← get
    match s.timers with
    | []                  => return none
    | (instant, fire) :: rest  => set { s with now := instant, timers := rest }; return (some fire)
  match due with
  | none      => return false
  | some fire => fire; return true

/-- **The clock this harness drives.** Its `sleep` schedules a fire and returns: the wait is a list insertion,
and the fire runs when the driver advances to it, resuming the awaiter on the driver's own thread.

The fire takes the **shared** route, and it is the general rule for a resume that is not a step's own
re-enqueue: an expiry is an *event*, not the sleeping step re-scheduling itself, and the thread that advances the
clock is not the sleeper's worker in general — so the delivery goes through the inject, whose push unparks a
parked waiter under its own lock, rather than onto a worker's own queue from another thread. The continuation
itself is `Item.ofDeferred`, so it still carries the sleeping computation's token and a route read at the index it
is fired with.

Pushing on the *sleeper's* local route was considered and rejected. It is owner-made under `runVirtual` —
`runWith` drives worker `0` on the calling thread and is the only advancer this seam is used with, so the
advancer and the sleeper's worker coincide — but that is a *caller's* convention, and this milestone deletes the
per-worker wake flag that such a convention would otherwise need: a `clock` driven from another thread, or from
another carrier, would push into a parked worker's own queue with nothing to wake it. A step's own re-enqueue is
the only resume that may take the local route; every other one takes the shared route, and this is one of them. -/
def HarnessClock.clock (hc : HarnessClock) : Clock :=
  { now   := hc.now
  , sleep := fun d => ⟨fun k ctx => do
      let fire : IO Unit := do ctx.resumeShared (Task.Item.ofDeferred ctx (k ()))
      let now0 ← hc.now
      hc.schedule (now0 + d.val.toNat) fire
      return ()⟩
  , schedule := fun d cancel fire => do
      let now0 ← hc.now
      hc.schedule (now0 + d.val.toNat) (do unless ← Task.Cancel.isSet cancel do fire)
  , scheduleCancel := fun d cancel fire onCancel => do
      let now0 ← hc.now
      hc.schedule (now0 + d.val.toNat) (do
        if ← Task.Cancel.isSet cancel then onCancel else fire)
  , swept := false }

/-- **The harness clock, composed with the executor wake a virtual driver needs.**

A timer armed from a thread other than the driver's — a raw resume on the loop's thread, say — strands
without this: the driver advances the harness clock only on an idle round, and a driver already parked on the
executor's condition variable receives no idle round for an arm. `push` is the off-carrier route (an
executor's `sharedPush`); the arm schedules the instant and then pushes a no-op item whose notification wakes
the park, and the driver's next idle round advances to it. A timer armed *before* the driver parks needs
nothing more than `clock`, which is why both exist. -/
def HarnessClock.clockWithWake (hc : HarnessClock) (push : Task.Item → BaseIO Unit) : Clock :=
  let base := HarnessClock.clock hc
  { base with
    schedule := fun d cancel fire => do
      base.schedule d cancel fire
      push (Task.Item.ofAction (pure ()))
    scheduleCancel := fun d cancel fire onCancel => do
      base.scheduleCancel d cancel fire onCancel
      push (Task.Item.ofAction (pure ())) }

/-- **Run a computation with a harness clock driving it.** The general driver with this clock's reading for the
metered path and one advance per idle round for the pool-empty wait. -/
def runVirtual (hc : HarnessClock) (e : Executor cap) (a : Task.Async α) : IO α :=
  runWith e hc.now hc.advance a

end LeanIn.Runtime

end
