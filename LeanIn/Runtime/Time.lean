module

public import Std
public import Std.Async.Timer
public import LeanIn.Runtime.Clock
public import LeanIn.Runtime.Leaf
public import LeanIn.Task.Basic


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
is in `docs/PERFORMANCE.md`.

**And the computation is cancelled when the deadline wins.** The computation arm is a spawned `Task` whose handle
is kept, not a `background` that drops it, so the fire that resolves the cell with `none` sets the loser's token
too: from then on `Item.fire` skips every step of it that is still queued, and a step it would have resumed — a
sleep's continuation, say — never runs. What that stops is the `Task.Async` computation itself. It does not
withdraw a raw read or write already submitted to libuv, and it does not preempt an operation already executing
on a blocking or foreign thread; those finish on their own and their result is the loser's write to ignore. Nor
does cancellation take a value from a computation that already produced one: both arms resolve through
`Join.resolveFirst`, so the first writer's outcome stands.

The cancelled wheel entry a winner leaves therefore now holds the computation's finished handle as well — a
settled join cell and a token — so that pair is released when the deadline is reaped rather than at the win. No
computation runs in the meantime, and the arm that is still executing is unaffected. -/

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

/-- **A spawned computation whose handle is resolved first-wins.** `Task.Async.spawn` completes its handle with
`Join.resolve`, which is loud on a second write; that is right for an ordinary computation and wrong for this
race, where the deadline's cancellation and the computation's own completion are two writers by design. This is
the same spawn shape with `Join.resolveFirst` at the completion, so whichever arrives first is the handle's value
and the other is ignored. It is private to the timeout combinator: the ordinary `Async.spawn`/`Join.resolve`
pair keeps its one-writer check. -/
private def spawnFirstWins (a : Task.Async α) : Task.Async (Task.Task α) := ⟨fun k ctx => do
  let cell ← Task.Join.new
  let cancel ← Task.Cancel.new
  ctx.resume (Task.Item.ofIndexed (some cancel) (fun i =>
    a.step (fun v ctx' => Task.Join.resolveFirst cell ctx'.resume v)
           { ctx.rebind i with cancel := cancel }))
  k ⟨cell, cancel⟩ ctx⟩

/-- **`a`, or `none` if `d` elapses first.** The first writer wins — the computation's own value, or the
timer's `none` — and the loser's write is ignored rather than being a defect.

The deadline is armed straight onto the clock's wheel as a fire that resolves the cell (`Clock.schedule`), not
as a spawned task parked on a `sleep`: a winning computation sets the timer's token and the fire goes inert, so
a `withTimeout` that returns early leaves a small cancelled wheel entry for the deadline to reap, not a parked
loser task that lives out the full interval. The computation is the one spawn — it must run on a carrier — and
its handle is kept so the other arm can stop it: the timer's fire cancels the spawned computation before it
resolves the cell with `none`, which sets the loser's token and so skips whatever of it is still queued. A
computation that won is cancelled too, harmlessly, if the token was not yet set when its value landed; its
value is already in the cell and the cancellation's own resolution belongs to a handle nothing awaits. The
computation arm resolves on its own route (`Task.Async.push`), so a waiter the resolution delivers is an item
on the queue the resolving arm is running on, while the timer's fire resolves on the shared route because it
runs on the loop thread, which owns no worker queue. -/
def withTimeout (c : Clock) (d : Std.Time.Millisecond.Offset) (a : Task.Async α) :
    Task.Async (Option α) := do
  let cell ← Task.Join.new
  let shared ← Task.Async.resumeShared
  let timerCancel ← (Task.Cancel.new : IO Task.Cancel)
  -- The computation is a `spawn` whose handle is kept rather than a `background` that drops it: the deadline's
  -- fire holds the handle, so winning the race can set the loser's token. The arm's value is `Unit` because it
  -- is a race participant and not a result — its value goes to `cell`, and `Task.cancel`'s own resolution of
  -- this handle is a cell nothing awaits.
  let computation ← spawnFirstWins (do
    let v ← a
    let push ← Task.Async.push
    Task.Join.resolveFirst cell push (some v)
    Task.Cancel.set timerCancel)
  -- The fire runs on the loop thread, which owns no worker queue, so both resolutions take the shared route.
  -- The loser is stopped *before* the deadline announces its win: from the moment its token is set, every step
  -- of it that is still queued is skipped at `Item.fire`, so no later step of the computation runs.
  c.schedule d timerCancel (do
    computation.cancel shared ()
    Task.Join.resolveFirst cell shared none)
  let token ← (Task.Cancel.new : IO Task.Cancel)
  Task.Async.await (show Task.Task (Option α) from ⟨cell, token⟩)

end LeanIn.Runtime

end
