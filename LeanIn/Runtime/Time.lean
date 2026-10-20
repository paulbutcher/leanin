module

import Std
import Std.Async.Timer
import LeanIn.Runtime.Clock
import LeanIn.Runtime.Leaf
import LeanIn.Task.Basic


public section
/-!
# Time on our carriers

W3: the timer leaf, and the one combinator a service cannot do without — `withTimeout`. The timers stay
`Std.Async`'s, on libuv's loop, and are awaited through W1's seam exactly as the sockets are; what is ours is
the combination, because a timeout is a *race* between a computation and a clock.

**Why a race needs its own resolution.** The task layer's `Join.resolve` states that a handle has one writer and
is loud when that is broken, which is right for a normal completion and wrong for a race: there, two writers are
the design and one of them must lose. `Join.resolveFirst` is that second law, and it is the whole of what this
file adds to the task layer.

**The timer is cancelled when the computation wins, and it was never a parked task.** The deadline is armed
straight onto the clock's wheel as a fire that resolves the cell (`Clock.schedule`), not as a spawned task
parked on a `sleep`, so there is no loser task to abandon. A winning computation sets the timer's token and the
fire goes inert; what it leaves is one small cancelled wheel entry for the deadline to reap, not a task that
lives out the interval. An earlier version armed the timer as a second background spawn and never cancelled it:
every `withTimeout` left a parked task for the full timeout, which at one read per request on a keep-alive
connection was the dominant per-request cost after the loop handoff was removed. The measurement that found it
is in `docs/PERFORMANCE.md`. -/

namespace LeanIn.Runtime

/-- **Sleep, awaited as one of ours.** The wait costs no carrier: the timer belongs to the installed clock and
its completion enqueues our resume, so a carrier that is sleeping is a carrier that is parked. Under `Clock.live`
that timer is libuv's; under a harness clock the wait is a list insertion and the fire is a virtual instant
rather than a libuv timeout. -/
def sleep (c : Clock) (d : Std.Time.Millisecond.Offset) : Task.Async Unit :=
  c.sleep d

/-- **A computation that never finishes.** A step that registers no continuation and calls none is exactly
that: nothing will ever schedule it again. It is what a timeout needs in order to actually time out, and it
needs no clock to say so. -/
def never {α : Type} : Task.Async α :=
  ⟨fun _ _ => pure ()⟩

/-- **`a`, or `none` if `d` elapses first.** The first writer wins — the computation's own value, or the
timer's `none` — and the loser's write is ignored rather than being a defect.

The deadline is armed straight onto the clock's wheel as a fire that resolves the cell (`Clock.schedule`), not
as a spawned task parked on a `sleep`: a winning computation sets the timer's token and the fire goes inert, so
a `withTimeout` that returns early leaves a small cancelled wheel entry for the deadline to reap, not a parked
loser task that lives out the full interval. The read arm is the one background spawn — the computation itself
must run on a carrier — and it resolves on its own route (`Task.Async.push`), so a waiter the resolution
delivers is an item on the queue the resolving arm is running on. -/
def withTimeout (c : Clock) (d : Std.Time.Millisecond.Offset) (a : Task.Async α) :
    Task.Async (Option α) := do
  let cell ← Task.Join.new
  let shared ← Task.Async.resumeShared
  let timerCancel ← (Task.Cancel.new : IO Task.Cancel)
  c.schedule d timerCancel (Task.Join.resolveFirst cell shared none)
  Task.background (do
    let v ← a
    let push ← Task.Async.push
    Task.Join.resolveFirst cell push (some v)
    Task.Cancel.set timerCancel)
  let token ← (Task.Cancel.new : IO Task.Cancel)
  Task.Async.await (show Task.Task (Option α) from ⟨cell, token⟩)

end LeanIn.Runtime

end
