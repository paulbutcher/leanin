module

public import Std
public import LeanIn.Task.Basic
public import LeanIn.Sched.Executor


public section
/-!
# The carrier boundary: what may cross it, and where that is enforced

`docs/interface.md` §5's O2 line — "nothing thread-unsafe crosses a carrier boundary" — has no Lean
counterpart at all: there is no `Send`, no `Sync`, and no marker anywhere under `LeanIn/`. This file is the
marker, and one thing about its shape decides everything else.

**A private constructor narrows a *type*, not an environment.** `Sendable`'s constructor is private to this
module, so a `Sendable` exists only where this library made one. That carries sendability for the values the
library itself builds — a task step, and the `Handle`/`Carriers` capabilities — and it is checked at both ends
of every crossing: the spawn API mints the marker, the carrier's queue requires it, and between them the type
carries it, so a call site that tries to enqueue an unmarked value does not elaborate. What it **cannot**
reach is a closure's captured environment: an `IO.Ref`, an unlocked handle, a cell shared by a caller. Lean
exposes no projection of a closure environment, so no constructor privacy reaches that, and the obligation is
a documented convention (`Runtime.spawn`'s docstring says it) rather than a theorem. That boundary is stated
rather than implied.

**Where the marker sits in this tree.** The marker is declared here, at the top of the task layer, and so are
the two ends that use it, because Lean's `private` is module-scoped: the only place a `Sendable Item` can be
minted is the module that declares the constructor. `LeanIn.Sched.Executor` therefore holds the raw
transactions — a queue push over plain `α` — and the boundary operations that *require* the marker are
declared here, taking a `Sendable`. The runtime never calls a raw push.

There is deliberately no instance for a cell, a closure or a `Task.Async`: the values the library is willing
to hand to another carrier are its own, and the compiler is what refuses the rest.
-/

namespace LeanIn

/-- A value this library built for crossing a carrier boundary. The constructor is private to this module, so
a `Sendable` exists only where the library made one — the boundary's surface is fixed by the library and not
by its callers. -/
structure Sendable (α : Type) where
  private mk :: of : α

/-- The accessor the boundary needs. The constructor stays private, so a `Sendable` still exists only where the
library made one; this projection is public so the push sites in `Sched` (a sibling namespace) can read it. -/
public def Sendable.val (s : Sendable α) : α :=
  match s with
  | ⟨x⟩ => x

/-- The values the library is willing to hand to another carrier. Instances are declared by this library, for
its own values; a module outside it cannot declare a useful one, because it cannot build the witness. -/
class Send (α : Type) where
  send : α → Sendable α

namespace Task

/-- **The only producer of a sendable step.** A step becomes crossable exactly where the library decides a
computation's step may run on another carrier. -/
def Item.sendable (it : Item) : Sendable Item := Sendable.mk it

instance : Send Item := ⟨Item.sendable⟩

end Task

namespace Sched

-- Anything holding a `Pool` needs `Inhabited α`, because the ring's ghost view falls back to it; the boundary
-- operations reach a pool, so the instance travels with them (the repository's existing convention).
variable {α : Type} [Inhabited α]

/-- **Push a step into the shared inject, across a carrier boundary** — the external route, and a queue whose
push has this signature and no other. -/
def Executor.pushInject (e : Executor α cap) (x : Sendable α) : BaseIO Unit :=
  e.pushInjectRaw x.val

/-- **Push a step into worker `i`'s own queue, across a carrier boundary** — the local route, the LIFO slot,
overflowing through the ring's placement rule when the slot displaces an occupant. -/
def Executor.spawnLocal (e : Executor α cap) (i : Nat) (x : Sendable α) : BaseIO Unit :=
  e.spawnLocalRaw i x.val

/-- **Push a step into worker `i`'s ring, across a carrier boundary** — the FIFO lane, the counterpart of the
slot lane above. -/
def Executor.submitLocal (e : Executor α cap) (i : Nat) (x : Sendable α) : BaseIO Unit :=
  e.submitLocalRaw i x.val

/-- **A worker's own route.** The step is re-scheduled on the worker that just ran it, so a chain stays on
the core its parent ran on — `docs/interface.md` §3's rule at P carriers. It is where a step becomes a
`Sendable` on the local route, which is why the queue's push requires one; a push on the **shared** route is
`Runtime.sharedPush`, which mints the marker the same way. Both are *read* at fire time rather than captured:
the route table a `Ctx` carries is built from this function (`Runtime.fired`), so a continuation another worker
delivers is re-bound to that worker rather than holding the route of the step that registered it. -/
def Executor.route (e : Executor α cap) (i : Nat) [Send α] : Route α :=
  ⟨fun x => e.spawnLocal i (Send.send x)⟩

end Sched

end LeanIn

end
