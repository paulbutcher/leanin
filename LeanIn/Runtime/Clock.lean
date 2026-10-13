import Std
import Std.Async.Timer
import LeanIn.Runtime.Basic
import LeanIn.Runtime.Leaf

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

/-- **The live clock's registry**: pending fires, earliest first, under one mutex. It replaces one libuv timer per
`sleep`, which cost a handle, a promise and a task per read and showed up, per thread, as a thread paying 2.02
context switches per request while burning 8 user ticks in a whole run — pure orchestration, a quarter of the
7.98 switches a request costs here. A `sleep` is now a list insertion and a fire is a list element; the *live*
driver is one dedicated thread that sleeps to the earliest instant and fires what is due, exiting when nothing is
pending so an idle service pays nothing. `Clock.live`'s `sleep` takes the same shape, so the interface and every
call site are unchanged; the virtual clock is untouched, so SC20-O3's `at == stall` still holds. -/
structure LiveClockState where
  timers : List (Nat × Task.Cancel × IO Unit) := []
deriving Inhabited

/-- The live clock's registry and pump state. -/
structure LiveClock where
  state   : Std.Mutex LiveClockState
  pumping : IO.Ref Bool
deriving Nonempty

/-- The live clock, created once at module init so `Clock.live` stays pure. -/
initialize liveClock : LiveClock ← do
  return { state := ← Std.Mutex.new {}, pumping := ← IO.mkRef false }

/-- Note a callback due at `instant`, keeping the list sorted earliest-first. -/
private def liveSchedule (instant : Nat) (c : Task.Cancel) (fire : IO Unit) : IO Unit :=
  liveClock.state.atomically do
    let s ← get
    let rec ins : List (Nat × Task.Cancel × IO Unit) → List (Nat × Task.Cancel × IO Unit)
      | []              => [(instant, c, fire)]
      | (t, tc, f) :: rest =>
          if instant < t then (instant, c, fire) :: (t, tc, f) :: rest else (t, tc, f) :: ins rest
    set { s with timers := ins s.timers }

/-- The pump: sleep to the earliest instant, fire everything due whose token is still unset, repeat. It exits
when the registry is empty; the next registration restarts it. One thread for the whole service rather than one
timer per wait. -/
private partial def livePump : IO Unit := do
  let next? ← liveClock.state.atomically do
    let s ← get
    match s.timers with
    | []              => return none
    | (t, _, _) :: _  => return some t
  match next? with
  | none   => liveClock.pumping.set false
  | some t => do
      let now ← IO.monoNanosNow
      if now < t then IO.sleep (((t - now) / 1000000 + 1).toUInt32)
      let now ← IO.monoNanosNow
      let due ← liveClock.state.atomically do
        let s ← get
        let (d, rest) := s.timers.partition fun p => p.1 <= now
        set { s with timers := rest }
        return d
      for (_, c, f) in due do
        unless ← c.isSet do f
      livePump

/-- Start the pump thread if it is not running. -/
private def liveKick : IO Unit := do
  if !(← liveClock.pumping.get) then
    liveClock.pumping.set true
    let _ ← IO.asTask (prio := _root_.Task.Priority.dedicated) livePump
    return ()

/-- **The production clock**: the live reading and a registry of real instants. A `sleep` registers a fire and
returns; the fire is inert if its token is set, which a winning read arranges by cancelling the loser. So a
deadline that loses to a completing read never fires, and a service under a read deadline pays no per-read timer,
task or thread wakeup. The interface and every call site are unchanged; the virtual clock is untouched, so
SC20-O3's `at == stall` still holds. -/
def Clock.live (_hooks : Hooks) : Clock :=
  { now   := IO.monoNanosNow
  , sleep := fun d => ⟨fun k ctx => do
      let fire : IO Unit := do
        unless ← ctx.cancel.isSet do
          ctx.resumeShared (Task.Item.ofDeferred ctx (k ()))
      let now0 ← IO.monoNanosNow
      liveSchedule (now0 + d.val.toNat * 1000000) ctx.cancel fire
      liveKick
      return ()⟩ }

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

/-- **Schedule a fire at `instant`**, keeping the list sorted and FIFO among equal instants. -/
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
      return ()⟩ }

/-- **Run a computation with a harness clock driving it.** The general driver with this clock's reading for the
metered path and one advance per idle round for the pool-empty wait. -/
def runVirtual (hc : HarnessClock) (e : Executor cap) (a : Task.Async α) : IO α :=
  runWith e hc.now hc.advance a

end LeanIn.Runtime
