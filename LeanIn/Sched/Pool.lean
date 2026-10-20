module

public import Std
public import LeanIn.Data.Ring
public import LeanIn.Data.Deque
public import LeanIn.Model.Pool


public section
/-!
# The pool, as the implementation keeps it

M3's refinement target. `LeanIn.Model.Pool` is the specification and this is the structure an executor
actually holds, so the file is built around the **projection** `toModel` and the commutation facts that make
"the implementation does what the model does" a theorem rather than an intention.

The ring is `LeanIn.Data.Ring` (M2b) rather than a `List`, because the model's `ring` is *bounded* and a
`List` would turn the capacity into a claim. `Ring.toList` is the ghost view the projection reads — the live
elements, oldest first — so `push` is the back-append and `pop` the front-take.

**The inject is not a field here.** It is shared by every carrier, so its store is one cell in
`LeanIn.Sched.Executor` and this pool is inject-free: the placement rule *returns* what overflows, and the
caller that holds the shared lock appends it. That is why the commutative facts below take the inject as a
parameter — `(p.toRing x).1` is the overflow a push produces, and the model's `toRing` threads the whole
shared list through instead. `Deque.lean` is the container the shared list is kept in.

Two things are deliberately not here. The wake protocol lives in the executor, and the script driver that
produces the executor's records lives with the client. What *is* here, unconditionally, is the overflow's
commutation: `Ring.keepFirst` sheds the newer half by index — the live count moves and nothing is copied — so
the halves this implementation keeps and evicts are the model's `take` and `drop` of its list.
`toModel_toRing` states that, and `toModel_submit` and `toModel_spawn` apply it to the two operations that
place work.
-/

namespace LeanIn.Sched

-- `Ring`'s operations need `Inhabited α` (`toList` falls back to `default`), and this pool is built on
-- them, so the instance travels with the type rather than being repeated at every mention of `Pool`.
variable {α : Type} [Inhabited α]

/-- The implementation's pool. Same fields as `LeanIn.Model.Pool`, with the ring as a container rather
than a list, and no inject: the shared queue is the executor's cell, not a worker's. -/
structure Pool (α : Type) (cap : Nat) where
  /-- The bounded FIFO ring: submitted at the back, taken from the front. -/
  ring      : Ring α cap
  /-- The one-slot LIFO buffer. Owner-local, never stolen. -/
  lifo      : Option α := none
  /-- LIFO polls used in the current tick: the *consecutive* slot polls since the allowance was last
  refreshed. -/
  lifoPolls : Nat := 0
  /-- Total submitted. -/
  pushed    : Nat := 0
  /-- Total taken, by owner or thief. -/
  taken     : Nat := 0
  /-- The most consecutive slot polls allowed; 3 in Tokio (`MAX_LIFO_POLLS_PER_TICK`). -/
  lifoCap   : Nat := 3
deriving Inhabited, Repr

/-- A fresh pool: an empty ring of `cap` slots and nothing held. -/
@[expose] def emptyPool (α : Type) (cap : Nat) : Pool α cap :=
  { ring := emptyRing α cap }

/-- The LIFO slot's contribution to a worker's own count: one when the slot is occupied. A named quantity
rather than a `Bool`-valued `if` at each use, both because the model's list says the same thing and because
two `if`s that print identically are two different terms when their `Decidable` instances differ. -/
@[expose] def Pool.slotCount (o : Option α) : Nat := if o.isSome then 1 else 0

omit [Inhabited α] in
theorem Pool.slotCount_none : Pool.slotCount (none : Option α) = 0 := rfl

omit [Inhabited α] in
theorem Pool.slotCount_some (x : α) : Pool.slotCount (some x) = 1 := rfl

/-- Work held in this pool's own queue: the ring and the LIFO slot. The inject is not part of a worker's
count; the composition's count is `Snapshot.held`. -/
@[expose] def Pool.inFlight (p : Pool α cap) : Nat :=
  p.ring.size + Pool.slotCount p.lifo

/-- **The projection.** The implementation's state as the specification describes it. "`Impl.push ⊑
Model.push`" is a statement about this function and `Pool.submit` below. -/
def Pool.toModel (p : Pool α cap) : Model.Pool α :=
  { ring      := p.ring.toList
    lifo      := p.lifo
    lifoPolls := p.lifoPolls
    pushed    := p.pushed
    taken     := p.taken
    cap       := cap
    lifoCap   := p.lifoCap }

/-- The owner's take off the ring: no allowance, no slot, no inject — the ring's front element. A thief
uses this too, which is where "the LIFO slot is never stolen" comes from: this function cannot see
`p.lifo`. -/
@[expose] def Pool.takeFromRing (p : Pool α cap) : Option α × Pool α cap :=
  match p.ring.pop with
  | (some x, r) => (some x, { p with ring := r, taken := p.taken + 1 })
  | (none, _)   => (none, p)

/-- **Which way a take's decision went.** The model's split (`takeSlot`/`takeFromRing`) does not distinguish
these, because none of its claims need to; a *report* does, because the tick's allowance is observable only
through which decision served the take. -/
inductive Served where
  /-- The LIFO slot served the take: a poll inside the tick's allowance. -/
  | slot
  /-- The slot was occupied with the allowance spent, so this decision cleared it for the shared inject and
  served the ring. -/
  | flushed
  /-- Neither: the ring. -/
  | queue
deriving Repr, BEq, DecidableEq

/-- **A take and the decision it made.** `observed` is the LIFO slot's occupant as the decision read it,
taken inside the same expression that decides — so it is this pool's record of that instant, not a reading
taken beside it — and `served` says which way the decision went. `flushed` is what the decision moved out of
the slot for the shared inject: the pool does not hold the inject, so the caller appends it.

The client's records are read through this because the allowance has no other observable: a pool that never
populated the slot would report `none` at every decision, and one that kept polling past its cap would report
a fourth `slot`. -/
structure TakeReport (α : Type) (cap : Nat) where
  /-- The LIFO slot's occupant before this take, as the decision observed it. -/
  observed : Option α
  /-- Which way the decision went. -/
  served   : Served
  /-- The item taken, if any. -/
  item     : Option α
  /-- The pool after the take. -/
  pool     : Pool α cap
  /-- What the decision moved out of the slot for the shared inject — empty, or one element after the
  flush. -/
  flushed  : List α

/-- A tick: the LIFO allowance refreshes. This is the executor's T4 operation and SC5's explicit refresh; the
take's own refresh is folded into `takeReport` below, which uses this. -/
@[expose] def Pool.tick (p : Pool α cap) : Pool α cap := { p with lifoPolls := 0 }

/-- The owner's take, with the decision it made — **and the allowance's refresh, which the decision
carries**.

The LIFO slot is preferred while its allowance lasts; **when the allowance runs out with a task still in the
slot, the slot is cleared for the shared inject before the ring is consulted**, so the allowance cannot strand
it. The allowance counts *consecutive* slot polls: a take the slot served spends it, and any other decision —
a flush, or a ring take — refreshes it, so a chain that keeps the slot occupied is interrupted at `lifoCap`
while a chain that yields is never demoted.

The refresh is folded in here rather than left to a caller's `tick`, because this is the one place that knows
which way the decision went, and both take spellings (`Pool.take`, and the executor's `takeFor`/`takeReport`)
read this transaction — so no take escapes the bound. A caller's own `Pool.tick` still means "refresh", and is
untouched. -/
def Pool.takeReport (p : Pool α cap) : TakeReport α cap :=
  let r : TakeReport α cap :=
    if p.lifoPolls < p.lifoCap then
      match p.lifo with
      | some x => { observed := some x, served := .slot, item := some x, flushed := [],
                    pool := { p with lifo := none, lifoPolls := p.lifoPolls + 1, taken := p.taken + 1 } }
      | none   =>
        let q := p.takeFromRing
        { observed := none, served := .queue, item := q.1, pool := q.2, flushed := [] }
    else
      match p.lifo with
      | some x =>
        let cleared := { p with lifo := none }
        let q := cleared.takeFromRing
        { observed := some x, served := .flushed, item := q.1, pool := q.2, flushed := [x] }
      | none   =>
        let q := p.takeFromRing
        { observed := none, served := .queue, item := q.1, pool := q.2, flushed := [] }
  { r with pool := if r.served = .slot then r.pool else r.pool.tick }

/-- The slot's own take, without the report: what the allowance's polls read. -/
def Pool.takeSlot (p : Pool α cap) : Option α × Pool α cap :=
  if p.lifoPolls < p.lifoCap then
    match p.lifo with
    | some x => (some x, { p with lifo := none, lifoPolls := p.lifoPolls + 1, taken := p.taken + 1 })
    | none   => (none, p)
  else (none, p)

/-- **Clear an occupied slot for the shared inject**: the item leaves the pool and the caller owns appending
it. Unconditional, because the caller is the one that knows the allowance is spent. -/
def Pool.flushSlot (p : Pool α cap) : Option α × Pool α cap :=
  match p.lifo with
  | some x => (some x, { p with lifo := none })
  | none   => (none, p)

/-- The owner's take: the decision without its report. One definition of the decision, so the two cannot
drift — the report is what the record reads, and this is what the worker uses. It is `takeReport`'s pool that
is kept, so this take carries the allowance's refresh too: a caller of `Pool.take` gets the same bounded
transaction as the executor's spellings, and there is no take that escapes the bound. -/
@[expose] def Pool.take (p : Pool α cap) : Option α × Pool α cap :=
  let r := p.takeReport
  (r.item, r.pool)

/-- **Where a task goes when it joins the ring** — the implementation's `Model.Pool.toRing`. Append at the
back if there is room. Otherwise the *newer* half leaves for the shared inject and the *older* half stays with
the new task: intake places work in the first half, so anything found in the second is provably not freshly
intaken.

`.1` is what the caller must append to the shared inject and `.2` is the pool; the inject is not this
structure's, which is why the eviction is returned rather than written. Factored out so `spawn` places the
task its LIFO slot displaces by the same rule, and there is one overflow rather than two that can drift. It
does not count: the task was counted when it entered the pool. -/
@[expose] def Pool.toRing (p : Pool α cap) (x : α) : List α × Pool α cap :=
  if p.ring.size < cap then
    ([], { p with ring := p.ring.push x })
  else
    -- The newer half leaves by *moving the live count*, not by reading the ring out and rebuilding it: the
    -- shed elements are at the back of the live range, and `WF` says only the live range is read, so nothing
    -- is copied and nothing is refilled. The one read of `toList` is over what is still held, and the list it
    -- produces is exactly the list the specification moves to `inject`.
    let half := p.ring.size / 2
    let live := p.ring.toList
    (live.drop half, { p with ring := (p.ring.keepFirst half).push x })

/-- **Submit, with overflow**: the placement rule, and the count. -/
@[expose] def Pool.submit (p : Pool α cap) (x : α) : List α × Pool α cap :=
  let r := p.toRing x
  (r.1, { r.2 with pushed := p.pushed + 1 })

/-- **Spawn, owner-local.** The new task takes the LIFO slot; the task it displaces goes to the run queue by
the same rule a submit uses, overflow included, so displacing it cannot silently drop it —
`schedule_local`, `worker.rs:1398`. -/
@[expose] def Pool.spawn (p : Pool α cap) (x : α) : List α × Pool α cap :=
  match p.lifo with
  | none   => ([], { p with lifo := some x, pushed := p.pushed + 1 })
  | some y => let r := p.toRing y; (r.1, { r.2 with lifo := some x, pushed := p.pushed + 1 })

/-! ### Agreement with the specification

The obligations of `interface.md` §6 that this file owns, stated against `toModel`: the accounting, a tick,
and the two operations that place work — each for the full ring as much as for one with room, and each read
with the overflow the shared inject receives. What makes the full cases go through is `keepFirst_toList`: the
eviction is the model's halving of the ghost view rather than a rearrangement free to disagree with it. -/

/-- **The accounting agrees.** `inFlight` reads the container's `size` plus the slot; the model reads the
length of its contents. `toList_length` is what makes the ring's two the same quantity, and the slot is one
case each because the model's list and the implementation's flag are the same fact written two ways. -/
theorem toModel_inFlight (p : Pool α cap) : p.inFlight = p.toModel.inFlight := by
  cases hl : p.lifo <;>
    simp [hl, Pool.inFlight, Pool.slotCount, Pool.toModel, Model.Pool.inFlight, Model.Pool.contents,
      toList_length]

/-- A tick refreshes the allowance on both sides. -/
theorem toModel_tick (p : Pool α cap) : (p.tick).toModel = (p.toModel).tick := by
  simp [Pool.tick, Pool.toModel, Model.Pool.tick]

/-! ### The count companions

What the executor's transactions need from the pool is not where an item came from but how the count moved.
These are those statements: placement, the take, the flush and a thief's steal — each with the shared list
read as a move rather than a loss, and each stated on the implementation's own counters.

The count companions are not the commutation theorems in the section below: a count companion says how a
counter moved, while the pair theorem says the container's *contents*, projected and threaded through the
shared list, are the specification's. Both are owned here; neither replaces the other. -/

/-- The placement rule writes the ring and nothing else of the pool's own state: a field it does not write
reads through it unchanged. -/
theorem toRing_lifo (p : Pool α cap) (x : α) : (p.toRing x).2.lifo = p.lifo := by
  unfold Pool.toRing
  split <;> rfl

/-- **Placement holds one more item, counting the overflow.** With room the ring appends and nothing leaves;
when full the newer half leaves for the shared list and the new task stays, so the pool plus the overflow
holds exactly one more than the pool did. -/
theorem toRing_inFlight (p : Pool α cap) (x : α) (_hw : p.ring.WF) (_hcap : 0 < cap) :
    (p.toRing x).2.inFlight + (p.toRing x).1.length = p.inFlight + 1 := by
  have hlen := toList_length p.ring
  by_cases hroom : p.ring.size < cap
  · simp only [Pool.toRing, ite_eq_left hroom, Pool.inFlight, Ring.push, List.length_nil]
    omega
  · have hhalf_le : p.ring.size / 2 ≤ p.ring.size := Nat.div_le_self _ _
    have hmin : min (p.ring.size / 2) p.ring.size = p.ring.size / 2 :=
      Nat.min_eq_left hhalf_le
    have hdrop : (p.ring.toList.drop (p.ring.size / 2)).length = p.ring.size - p.ring.size / 2 := by
      rw [List.length_drop, toList_length]
    simp only [Pool.toRing, ite_eq_right hroom, Pool.inFlight, Ring.keepFirst, Ring.push]
    rw [hmin, hdrop]
    omega

/-- **Submission holds one more item**, full ring included, counting the overflow the shared list takes. -/
theorem submit_inFlight (p : Pool α cap) (x : α) (_hw : p.ring.WF) (hcap : 0 < cap) :
    (p.submit x).2.inFlight + (p.submit x).1.length = p.inFlight + 1 := by
  simp only [Pool.submit]
  exact toRing_inFlight p x _hw hcap

/-- **A take off the ring holds one fewer item.** The count companion of `takeFromRing`: a successful take
removes exactly one, and the failure arm is the one that had nothing to remove. -/
theorem takeFromRing_inFlight (p : Pool α cap) (hw : p.ring.WF)
    (h : (p.takeFromRing).1.isSome) : (p.takeFromRing).2.inFlight + 1 = p.inFlight := by
  unfold Pool.takeFromRing at h ⊢
  cases hp : p.ring.pop with
  | mk a b =>
    cases a with
    | some x =>
      have hpos : 0 < p.ring.size := by
        have hsome : (p.ring.pop).1.isSome := by rw [hp]; rfl
        exact pop_isSome_size hsome
      have hps : b.size + 1 = p.ring.size := by
        have h := pop_size p.ring hw hpos
        rw [hp] at h
        exact h
      simp only [Pool.inFlight]
      omega
    | none =>
      have hcontra : ¬ (p.takeFromRing).1.isSome := by simp [Pool.takeFromRing, hp]
      exact absurd h hcontra

/-- The flush moves the slot's task out of the pool and changes nothing else — a move, so the pool's own
count is the only thing that falls. It is only true when the slot really held that task. -/
theorem flushSlot_inFlight {α : Type} {cap : Nat} {p : Pool α cap} {x : α} (hl : p.lifo = some x) :
    ({ p with lifo := none } : Pool α cap).inFlight + 1 = p.inFlight := by
  simp [Pool.inFlight, Pool.slotCount, hl]

omit [Inhabited α] in
/-- A tick changes only the allowance, so the pool's own count is untouched: the refresh in a take's
transaction moves no item. -/
theorem tick_inFlight (p : Pool α cap) : (p.tick).inFlight = p.inFlight := rfl

/-- **A reported take holds one fewer item**, whichever way the decision went: the slot arm removes the
slot's task, the queue arms remove one off the ring, and the flush clears the slot for the shared list —
whose append is the caller's, and therefore counted beside this by `flushed`. -/
theorem takeReport_inFlight (p : Pool α cap) (hw : p.ring.WF) (h : (p.takeReport).item.isSome) :
    (p.takeReport).pool.inFlight + 1 + (p.takeReport).flushed.length = p.inFlight := by
  by_cases hpolls : p.lifoPolls < p.lifoCap
  · cases hl : p.lifo with
    | some x =>
      simp [Pool.takeReport, Pool.inFlight, Pool.slotCount_none, Pool.slotCount_some, hpolls, hl]
    | none =>
      have h' : (p.takeFromRing).1.isSome := by simpa [Pool.takeReport, hpolls, hl] using h
      simpa [Pool.takeReport, Pool.tick, Pool.inFlight, hpolls, hl] using takeFromRing_inFlight p hw h'
  · cases hl : p.lifo with
    | some x =>
      have h' : (({ p with lifo := none } : Pool α cap).takeFromRing).1.isSome := by
        simpa [Pool.takeReport, hpolls, hl] using h
      have hc := takeFromRing_inFlight ({ p with lifo := none } : Pool α cap) hw h'
      have hf := flushSlot_inFlight (p := p) hl
      have hgoal : (p.takeReport).pool =
          (({ p with lifo := none } : Pool α cap).takeFromRing.2).tick := by
        simp [Pool.takeReport, hpolls, hl]
      have hfl : (p.takeReport).flushed.length = 1 := by
        simp [Pool.takeReport, hpolls, hl]
      rw [hgoal, hfl, tick_inFlight]
      omega
    | none =>
      have h' : (p.takeFromRing).1.isSome := by simpa [Pool.takeReport, hpolls, hl] using h
      simpa [Pool.takeReport, Pool.tick, Pool.inFlight, hpolls, hl] using takeFromRing_inFlight p hw h'

omit [Inhabited α] in
/-- **The allowance's own law.** A take the slot served spends the allowance; any other decision — a flush or
a ring take — refreshes it. So `lifoPolls` counts *consecutive* slot polls, and the count is per carrier
because the pool is. -/
theorem takeReport_lifoPolls (p : Pool α cap) :
    (p.takeReport).pool.lifoPolls = if (p.takeReport).served = .slot then p.lifoPolls + 1 else 0 := by
  by_cases hpolls : p.lifoPolls < p.lifoCap
  · cases hl : p.lifo with
    | some x => simp [Pool.takeReport, hpolls, hl]
    | none => simp [Pool.takeReport, Pool.tick, hpolls, hl]
  · cases hl : p.lifo with
    | some x => simp [Pool.takeReport, Pool.tick, hpolls, hl]
    | none => simp [Pool.takeReport, Pool.tick, hpolls, hl]

omit [Inhabited α] in
/-- **A spent allowance with the slot occupied flushes rather than polling again**, and reports the occupant
as the decision observed it: the flush is the bound taking effect, and its item is the one it cleared for the
shared inject. -/
theorem takeReport_flushes_when_spent (p : Pool α cap) (h : ¬ p.lifoPolls < p.lifoCap) (hl : p.lifo ≠ none) :
    (p.takeReport).served = .flushed ∧ (p.takeReport).observed = p.lifo := by
  cases hsome : p.lifo with
  | none => simp [hsome] at hl
  | some x => simp [Pool.takeReport, h, hsome]

omit [Inhabited α] in
/-- **The allowance stays bounded by its cap**: a slot serve increments toward the cap, and every other
decision refreshes to zero. -/
theorem takeReport_bounded (p : Pool α cap) :
    (p.takeReport).pool.lifoPolls ≤ (p.takeReport).pool.lifoCap := by
  by_cases hpolls : p.lifoPolls < p.lifoCap
  · cases hl : p.lifo with
    | some x =>
      simp [Pool.takeReport, hpolls, hl]
      omega
    | none => simp [Pool.takeReport, Pool.tick, hpolls, hl]
  · cases hl : p.lifo with
    | some x => simp [Pool.takeReport, Pool.tick, hpolls, hl]
    | none => simp [Pool.takeReport, Pool.tick, hpolls, hl]

/-- **A spawn holds one more item.** The slot is written either way, and the task it displaced is placed
rather than dropped. -/
theorem spawn_inFlight (p : Pool α cap) (x : α) (hw : p.ring.WF) (hcap : 0 < cap) :
    (p.spawn x).2.inFlight + (p.spawn x).1.length = p.inFlight + 1 := by
  cases hl : p.lifo with
  | none =>
    simp only [Pool.spawn, hl, Pool.inFlight, Pool.slotCount_some, Pool.slotCount_none,
      List.length_nil]
    first | omega | skip
  | some y =>
    have hring := toRing_inFlight p y hw hcap
    have hlf := toRing_lifo p y
    simp only [Pool.inFlight] at hring ⊢
    rw [hlf] at hring
    simp only [Pool.spawn, hl, Pool.slotCount_some]
    first | omega | skip

/-! ### The commutation of the placement rule with the specification

The obligations of `interface.md` §6 that this file owns, read at the *pair* — the pool and the shared list
together — rather than at the pool alone: `toModel_toRing`, `toModel_submit` and `toModel_spawn` say that the
implementation's placement, projected into the specification and threaded through the shared list, is exactly
the specification's placement. The count companions above are a different statement — how a count moves — and
neither replaces the other: the pair form is what ties the container's *contents* to the model's `ring`, and it
is the proof half of the refinement table.

What makes the full cases go through is `keepFirst_toList` (the eviction is the model's `take` of the ghost
view) and `push_toList` (the append), with `toList_length` tying the container's `size` to the ghost view's
length, so the two `if`s split on the same condition. -/

/-- **Placement commutes with the projection.** The implementation's `toRing` returns the overflow for the
caller to append; threading it through the shared list gives the specification's `toRing`, whose `.1` is the
whole shared list after the append and whose `.2` is the projected pool. -/
theorem toModel_toRing (p : Pool α cap) (inj : List α) (x : α) (hw : p.ring.WF) (hcap : 0 < cap) :
    p.toModel.toRing inj x = (inj ++ (p.toRing x).1, (p.toRing x).2.toModel) := by
  have hlen := toList_length p.ring
  unfold Model.Pool.toRing Pool.toRing
  by_cases hroom : p.ring.size < cap
  · have hroom' : p.toModel.ring.length < p.toModel.cap := by simp only [Pool.toModel]; omega
    rw [ite_eq_left hroom', ite_eq_left hroom]
    simp only [List.append_nil]
    refine Prod.ext rfl ?_
    simp only [Pool.toModel]
    rw [push_toList p.ring x hw hroom]
  · have hfull : ¬ (p.toModel.ring.length < p.toModel.cap) := by simp only [Pool.toModel]; omega
    rw [ite_eq_right hfull, ite_eq_right hroom]
    refine Prod.ext ?_ ?_
    · simp only [Pool.toModel, hlen]
    · have hmin : min (p.ring.size / 2) p.ring.size = p.ring.size / 2 :=
        Nat.min_eq_left (Nat.div_le_self _ _)
      have hle : p.ring.size ≤ cap := hw.2.1
      have hw' : (p.ring.keepFirst (p.ring.size / 2)).WF := keepFirst_wf p.ring _ hw
      have hroom' : (p.ring.keepFirst (p.ring.size / 2)).size < cap := by
        simp only [Ring.keepFirst, hmin]; omega
      simp only [Pool.toModel]
      rw [push_toList (p.ring.keepFirst (p.ring.size / 2)) x hw' hroom', keepFirst_toList, hmin, hlen]

/-- **Submission commutes with the projection.** `Model.Pool.submit` is `toRing` plus the count; the count is
`toModel`'s own `pushed`, so the pair theorem above carries it. -/
theorem toModel_submit (p : Pool α cap) (inj : List α) (x : α) (hw : p.ring.WF) (hcap : 0 < cap) :
    p.toModel.submit inj x = (inj ++ (p.submit x).1, (p.submit x).2.toModel) := by
  unfold Model.Pool.submit Pool.submit
  rw [toModel_toRing p inj x hw hcap]
  rfl

/-- **Spawn commutes with the projection.** A free slot holds the new task and the shared list is untouched;
an occupied slot displaces its occupant through `toRing`, both sides, and the displaced task is placed rather
than dropped. -/
theorem toModel_spawn (p : Pool α cap) (inj : List α) (x : α) (hw : p.ring.WF) (hcap : 0 < cap) :
    p.toModel.spawn inj x = (inj ++ (p.spawn x).1, (p.spawn x).2.toModel) := by
  unfold Model.Pool.spawn Pool.spawn
  cases hl : p.lifo with
  | none =>
    have hq : p.toModel.lifo = none := by simp only [Pool.toModel, hl]
    rw [hq]
    simp only [Pool.toModel, List.append_nil]
  | some y =>
    have hq : p.toModel.lifo = some y := by simp only [Pool.toModel, hl]
    rw [hq]
    dsimp only
    rw [toModel_toRing p inj y hw hcap]
    simp only [Pool.toModel]

/-! ### The audit

The take path's laws are stated over the pool alone and must rest on nothing beyond the standard axioms —
the pool is *about* the primitives, so a proof that depended on a bridge axiom would be circular.
`#print axioms` is the check. -/

#print axioms LeanIn.Sched.takeReport_inFlight
#print axioms LeanIn.Sched.tick_inFlight
#print axioms LeanIn.Sched.takeReport_lifoPolls
#print axioms LeanIn.Sched.takeReport_flushes_when_spent
#print axioms LeanIn.Sched.takeReport_bounded

end LeanIn.Sched

end
