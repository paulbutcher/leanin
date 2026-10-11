import Std

/-!
# The pool model

The pure model the interface of [`docs/interface.md`](../../docs/interface.md) is stated against, and
the shape the concurrent implementation must refine (D5).

This is not `List α` dressed up. The interesting content is the *worker shape* Tokio actually uses
(`docs/tokio-map.md` §2): a bounded FIFO ring, a one-slot LIFO buffer with a per-tick allowance, and a
shared inject queue that receives overflow. With those, "no work is lost" stops being obvious and
becomes a conservation law with a proof — which is the point, since Tokio asserts it at runtime
(`queue.rs:571`, a non-empty queue at drop is a bug) rather than proving it.

## Where the fields come from

| Field | Tokio |
|---|---|
| `ring`, `cap` | the 256-slot local queue, `push_back` at the back and `pop` at the front — **FIFO**, not a LIFO deque |
| `lifo`, `lifoPolls`, `lifoCap` | the LIFO slot and `MAX_LIFO_POLLS_PER_TICK = 3` (`worker.rs:265`) |
| `pushed`, `taken` | bookkeeping for the conservation law; not in Tokio, and the reason it can only assert |

## The inject is not a field, and that is the multi-carrier decision

A worker's queue is its own — a ring and a LIFO slot behind one lock — and the inject is shared by every
worker. So the shared list is *not* a pool field: the placement rule returns what overflows (`.1` of
`toRing`/`submit`/`spawn`) and the layer that owns the shared lock appends it, and the pool's own
conservation law is stated **with the inject the pool threaded through**:

`Pool.Consistent p inj` is `p.inFlight + inj.length + p.taken = p.pushed`.

The global law — every worker's held work plus the inject against one submission count — is
`Multi.Consistent`, one layer up; `LeanIn.Model.Inject` is the shared list itself.

## What is modelled and what is not

Modelled: ordering, capacity, overflow, the LIFO allowance, and the *flush* that stops the allowance
stranding work. Not modelled: the mutex, the ticket, memory ordering — those are `Theory/Bridge.lean`'s
business. A single `Pool` here is what one worker sees under its own lock.
-/

namespace LeanIn

-- The pure model lives under `LeanIn.Model`, matching its file path, because M3's implementation is
-- `LeanIn.Sched`: a model structure declared directly under `LeanIn` would share that namespace with it,
-- which is what happened silently until the collision was looked for.
namespace Model

structure Pool (α : Type) where
  /-- The bounded FIFO ring: submitted at the back, taken from the front. -/
  ring      : List α := []
  /-- The one-slot LIFO buffer. Owner-local, never stolen. -/
  lifo      : Option α := none
  /-- LIFO polls used in the current tick. -/
  lifoPolls : Nat := 0
  /-- Total submitted. -/
  pushed    : Nat := 0
  /-- Total taken, by owner or thief. -/
  taken     : Nat := 0
  /-- Ring capacity. 256 in Tokio; any value ≥ 2 here. -/
  cap       : Nat := 256
  /-- LIFO polls allowed per tick. 3 in Tokio. -/
  lifoCap   : Nat := 3
deriving Inhabited, Repr

/-- The all-empty pool, written out field by field so that examples reduce — `default` does not
unfold, which silently turns a vacuity check into an unprovable goal. -/
def emptyPool (α : Type) : Pool α :=
  { ring := [], lifo := none, lifoPolls := 0,
    pushed := 0, taken := 0, cap := 256, lifoCap := 3 }

/-- **Everything this pool holds, as one list**: the ring, then the slot. The count is its length, so every
count law below is a list-length law — which is also why the count is a *function* of the pool rather than a
stored counter: two counters that move together by coincidence are not the same quantity. -/
def Pool.contents (p : Pool α) : List α := p.ring ++ p.lifo.toList

/-- Work this pool holds: its ring and its LIFO slot. The inject is not this pool's. -/
def Pool.inFlight (p : Pool α) : Nat := p.contents.length

/-- **No lost work, with the shared inject the pool threads through.** Everything ever submitted to this
pool is still held here or in the shared list, or was taken. This is Tokio's runtime assertion, as an
equation; the composition's version is `Multi.Consistent`. -/
def Pool.Consistent (p : Pool α) (inj : List α) : Prop := p.inFlight + inj.length + p.taken = p.pushed

/-- Work is present in the pool's own queue. -/
def Pool.HasWork (p : Pool α) : Prop := p.ring ≠ [] ∨ p.lifo.isSome

/-- The ring stays within capacity. -/
def Pool.Bounded (p : Pool α) : Prop := p.ring.length ≤ p.cap

/-! ### Taking -/

/-- The ring's own take: its front element. A thief uses this too, which is where "the LIFO slot is never
stolen" is expressed — this function cannot see `p.lifo`. The shared inject is not a fallback here: the
layer owning the shared lock serves it, after this pool's own queue is empty. -/
def Pool.takeFromRing (p : Pool α) : Option α × Pool α :=
  match p.ring with
  | x :: rest => (some x, { p with ring := rest, taken := p.taken + 1 })
  | []        => (none, p)

/-- The slot's own take: served while the tick's allowance lasts, and nothing otherwise. -/
def Pool.takeSlot (p : Pool α) : Option α × Pool α :=
  if p.lifoPolls < p.lifoCap then
    match p.lifo with
    | some x => (some x, { p with lifo := none, lifoPolls := p.lifoPolls + 1, taken := p.taken + 1 })
    | none   => (none, p)
  else (none, p)

/-- **Clear an occupied slot for the shared inject.** The item leaves the pool and the caller owns both the
append and the count that follows it — `flushSlot_conserves` states the accounting the caller composes.

Unconditional, because the caller is the one that knows the tick's allowance is spent; the take below is
what refuses to clear a slot it may still serve. -/
def Pool.flushSlot (p : Pool α) : Option α × Pool α :=
  match p.lifo with
  | some x => (some x, { p with lifo := none })
  | none   => (none, p)

/-- The owner's take over its own queue.

The LIFO slot is preferred while the tick's allowance lasts. **When the allowance runs out with a task
still in the slot, the executor clears the slot for the shared inject before it serves the ring** —
otherwise the allowance could strand it, which is the same hazard `worker.rs:479` avoids when a worker gives
up its core. That clear is not this function's, because its destination is shared: the pool says which slot
is occupied (`takeSlot` reports `none` once the allowance is spent), and the executor's decision is the one
`LeanIn.Sched.Pool.takeReport` records. -/
def Pool.take (p : Pool α) : Option α × Pool α :=
  if p.lifoPolls < p.lifoCap then
    match p.lifo with
    | some x => (some x, { p with lifo := none, lifoPolls := p.lifoPolls + 1, taken := p.taken + 1 })
    | none   => p.takeFromRing
  else
    p.takeFromRing

/-- A thief takes one element from the front of a victim's ring. It cannot reach the LIFO slot. -/
def Pool.steal (victim : Pool α) : Option α × Pool α := victim.takeFromRing

/-- A tick: the LIFO allowance refreshes. -/
def Pool.tick (p : Pool α) : Pool α := { p with lifoPolls := 0 }

/-! ### Submitting -/

/-- **Where a task goes when it joins the ring, and what the shared inject receives.**

Append at the back if there is room; otherwise move **half** the ring to the inject and append — half, not
all, so the ring keeps the older work and does not immediately refill into another overflow
(`queue.rs:253`).

`.1` is the shared list after the overflow is appended and `.2` is the pool: the inject belongs to the layer
that owns the shared lock, so the eviction is returned rather than written.

Factored out because `spawn` needs the *same* rule for the task its LIFO slot displaces, and there should be
one definition of the overflow rather than two that can drift. It does not count: the displaced task is
already in the pool. -/
def Pool.toRing (p : Pool α) (inj : List α) (x : α) : List α × Pool α :=
  if p.ring.length < p.cap then
    (inj, { p with ring := p.ring ++ [x] })
  else
    (inj ++ p.ring.drop (p.ring.length / 2),
     { p with ring := p.ring.take (p.ring.length / 2) ++ [x] })

/-- Submit, with overflow: the placement rule, and the count. -/
def Pool.submit (p : Pool α) (inj : List α) (x : α) : List α × Pool α :=
  let r := p.toRing inj x
  (r.1, { r.2 with pushed := p.pushed + 1 })

/-- **Spawn, owner-local.** The new task takes the LIFO slot; the task it displaces goes to the run queue by
the same rule a submit uses, overflow included, so displacing it cannot silently drop it — `schedule_local`,
`worker.rs:1398`.

This is the write side of `next_local_task` in the model's `take`, and it is placed *before* the ring rather
than in `inject` because the slot's whole purpose is to keep a message pass on one core. It is also why the
slot is never stolen: a thief reaches the ring and nothing else. -/
def Pool.spawn (p : Pool α) (inj : List α) (x : α) : List α × Pool α :=
  match p.lifo with
  | none   => (inj, { p with lifo := some x, pushed := p.pushed + 1 })
  | some y => let r := p.toRing inj y; (r.1, { r.2 with lifo := some x, pushed := p.pushed + 1 })

/-! ### What the overflow keeps, and what it evicts

The two halves are not interchangeable, and `queue.rs:295` gives the reason: intake places work in the
*first* half of the ring, so a task found in the *second* half is provably not one just intaken — "at
least not until after we have polled it at least once". That is only true if the *second* half is what
gets evicted, which is what these two examples pin. -/

/-- The ring keeps the older half, plus the new task. -/
example : (({(emptyPool Nat) with cap := 4, ring := [0, 1, 2, 3]}).submit [] 4).2.ring = [0, 1, 4] := by
  decide

/-- The newer half is what leaves for `inject`. -/
example : (({(emptyPool Nat) with cap := 4, ring := [0, 1, 2, 3]}).submit [] 4).1.drop 0 = [2, 3] := by
  decide

/-! ### Spawning -/

/-- A spawn into a free slot occupies it, and the ring is untouched. -/
example : ((emptyPool Nat).spawn [] 7).2.lifo = some 7 := by decide

/-- The hypothesis `take_slot_first` consumes is **reachable and staged by a real operation**: a
local `spawn` populates the slot, and the fresh pool's poll count is within the allowance — so the
lemma is not about an unreachable state, and the slot is not hand-filled. -/
example : ((emptyPool Nat).spawn [] 7).2.lifo = some 7 ∧ ((emptyPool Nat).spawn [] 7).2.lifoPolls < 3 := by
  decide

/-- A second spawn takes the slot, displacing the first. -/
example : (((emptyPool Nat).spawn [] 1).2.spawn [] 7).2.lifo = some 7 := by decide

/-- …and the displaced task goes to the ring's *back*, not to `inject` — the ring had room. -/
example : (((emptyPool Nat).spawn [] 1).2.spawn [] 7).2.ring = [1] := by decide

/-- Both spawns count as submitted, and the displaced task is not counted twice. -/
example : (((emptyPool Nat).spawn [] 1).2.spawn [] 7).2.pushed = 2 := by decide

/-- Displacing from a *full* ring goes through the same overflow rule `submit` uses, so the displaced
task is placed rather than dropped. -/
example :
    (({(emptyPool Nat) with cap := 4, ring := [0, 1, 2, 3], lifo := some 5}).spawn [] 7).2.ring
      = [0, 1, 5] := by
  decide

/-- …with the newer half leaving for the shared list, exactly as in the `submit` case above. -/
example :
    (({(emptyPool Nat) with cap := 4, ring := [0, 1, 2, 3], lifo := some 5}).spawn [] 7).1
      = [2, 3] := by
  decide

/-- …and the spawn itself holds the slot. -/
example :
    (({(emptyPool Nat) with cap := 4, ring := [0, 1, 2, 3], lifo := some 5}).spawn [] 7).2.lifo
      = some 7 := by
  decide

/-! ### The conservation law -/

/-- `take` and `drop` partition a list, at any split point. Stated separately because `omega` treats
`l.length / 2` as an opaque atom and cannot relate it to `l.length` on its own. -/
theorem length_take_add_drop {α : Type} (l : List α) (n : Nat) :
    (l.take n).length + (l.drop n).length = l.length := by
  rw [List.length_take, List.length_drop]
  by_cases h : n ≤ l.length
  · rw [Nat.min_eq_left h]; omega
  · have hle : l.length ≤ n := Nat.le_of_lt (Nat.lt_of_not_le h)
    rw [Nat.min_eq_right hle, Nat.sub_eq_zero_of_le hle]
    omega

theorem takeFromRing_conserves {p : Pool α} (inj : List α) (h : p.Consistent inj) :
    (p.takeFromRing).2.Consistent inj := by
  simp only [Pool.takeFromRing]
  cases hr : p.ring with
  | nil => exact h
  | cons x rest =>
    simp only [hr, Pool.Consistent, Pool.inFlight, Pool.contents, List.length_append,
      List.length_cons] at h ⊢
    omega

theorem takeSlot_conserves {p : Pool α} (inj : List α) (h : p.Consistent inj) :
    (p.takeSlot).2.Consistent inj := by
  simp only [Pool.takeSlot]
  by_cases hp : p.lifoPolls < p.lifoCap
  · rw [ite_eq_left hp]
    cases hl : p.lifo with
    | none => exact h
    | some x =>
      simp only [hl, Pool.Consistent, Pool.inFlight, Pool.contents, Option.toList_some,
        Option.toList_none, List.length_append, List.length_nil, List.length_singleton] at h ⊢
      omega
  · rw [ite_eq_right hp]
    exact h

theorem take_conserves {p : Pool α} (inj : List α) (h : p.Consistent inj) :
    (p.take).2.Consistent inj := by
  simp only [Pool.take]
  by_cases hp : p.lifoPolls < p.lifoCap
  · rw [ite_eq_left hp]
    cases hl : p.lifo with
    | none   => exact takeFromRing_conserves inj h
    | some x =>
      simp only [hl, Pool.Consistent, Pool.inFlight, Pool.contents, Option.toList_some,
        Option.toList_none, List.length_append, List.length_nil, List.length_singleton] at h ⊢
      omega
  · rw [ite_eq_right hp]
    exact takeFromRing_conserves inj h

/-- **The slot is taken first while the allowance lasts.** A one-line restatement of `take`'s own
definition, and the model half of the priority argument: `.high` places a task in the slot
(`Pool.spawn`) where the owner takes it before the ring, `.normal` appends it to the ring
(`Pool.submit`). The priorities themselves are not modelled — a modelled priority ordering would be a
fairness statement the interface forbids — so what is stated is the *mechanism*, not a promise. -/
theorem take_slot_first (p : Pool α) (x : α)
    (hl : p.lifo = some x) (hp : p.lifoPolls < p.lifoCap) : (p.take).1 = some x := by
  simp only [Pool.take, ite_eq_left hp, hl]

theorem steal_conserves {p : Pool α} (inj : List α) (h : p.Consistent inj) :
    (p.steal).2.Consistent inj :=
  takeFromRing_conserves inj h

/-- **The flush's accounting, composed by its caller.** Clearing the slot takes the task out of the pool;
the append the caller performs on the shared list is what keeps the total. This is the law the executor's
flush path uses — the pool cannot state it alone, because the destination is shared. -/
theorem flushSlot_conserves {p : Pool α} {x : α} (inj : List α) (hl : p.lifo = some x)
    (h : p.Consistent inj) : (p.flushSlot).2.Consistent (inj ++ [x]) := by
  simp only [Pool.flushSlot]
  rw [hl]
  simp only [Pool.Consistent, Pool.inFlight, Pool.contents, Option.toList_none, List.length_nil,
    List.length_append, List.length_singleton, hl, Option.toList_some] at h ⊢
  omega

/-- **The placement rule loses nothing.** The task joins the ring, and if the ring was full its newer
half moves to the shared list, so ring plus what the caller appends grows by exactly the one task placed.

This is deliberately *not* a conservation law for `toRing` on its own: a task placed by this rule was
counted when it entered the pool, not here, so `pushed` does not move. Both callers supply that count —
`submit` for its task, `spawn` for the spawn, since the task it displaces was already counted. -/
theorem toRing_len (p : Pool α) (inj : List α) (x : α) :
    (p.toRing inj x).2.ring.length + (p.toRing inj x).1.length
      = p.ring.length + inj.length + 1 := by
  simp only [Pool.toRing]
  by_cases hc : p.ring.length < p.cap
  · rw [ite_eq_left hc]
    simp only [List.length_append, List.length_singleton]
    omega
  · rw [ite_eq_right hc]
    simp only [List.length_append, List.length_singleton]
    have hsum := length_take_add_drop p.ring (p.ring.length / 2)
    omega

theorem submit_conserves {p : Pool α} (x : α) (inj : List α) (h : p.Consistent inj) :
    (p.submit inj x).2.Consistent (p.submit inj x).1 := by
  simp only [Pool.Consistent, Pool.inFlight, Pool.contents, List.length_append] at h
  simp only [Pool.submit, Pool.toRing]
  by_cases hc : p.ring.length < p.cap
  · rw [ite_eq_left hc]
    simp only [Pool.Consistent, Pool.inFlight, Pool.contents, List.length_append,
      List.length_singleton] at h ⊢
    omega
  · rw [ite_eq_right hc]
    simp only [Pool.Consistent, Pool.inFlight, Pool.contents, List.length_append,
      List.length_singleton] at h ⊢
    have hsum := length_take_add_drop p.ring (p.ring.length / 2)
    omega

theorem tick_conserves {p : Pool α} (inj : List α) (h : p.Consistent inj) :
    (p.tick).Consistent inj := h

/-! ### Capacity -/

/-- The ring stays within capacity under the placement rule; the newer half leaves for the shared list
instead. -/
theorem toRing_bounded {p : Pool α} {inj : List α} {x : α} (hb : p.Bounded) (hcap : 2 ≤ p.cap) :
    (p.toRing inj x).2.Bounded := by
  simp only [Pool.toRing]
  by_cases hc : p.ring.length < p.cap
  · rw [ite_eq_left hc]
    simp only [Pool.Bounded, List.length_append, List.length_singleton]
    omega
  · rw [ite_eq_right hc]
    simp only [Pool.Bounded, List.length_append, List.length_singleton]
    have hb' : p.ring.length ≤ p.cap := hb
    have hdiv : p.ring.length / 2 ≤ p.ring.length := Nat.div_le_self _ _
    have htake : (p.ring.take (p.ring.length / 2)).length = p.ring.length / 2 := by
      rw [List.length_take, Nat.min_eq_left hdiv]
    omega

theorem submit_bounded {p : Pool α} {x : α} (inj : List α) (hb : p.Bounded) (hcap : 2 ≤ p.cap) :
    (p.submit inj x).2.Bounded := by
  simp only [Pool.submit]
  exact toRing_bounded (p := p) (inj := inj) (x := x) hb hcap

/-! ### Counts

What the executor's transactions need from the pool is not where an item came from but how the count moved.
These are those statements: placement, the take, the flush, and a thief's steal — each with the shared list
read as a move rather than a loss. -/

/-- **The placement rule holds one more item**: the halves partition the ring, the caller appends the
eviction, and the task placed is added — so the pool plus the shared list grows by exactly one. -/
theorem toRing_inFlight (p : Pool α) (inj : List α) (x : α) :
    (p.toRing inj x).2.inFlight + (p.toRing inj x).1.length = p.inFlight + inj.length + 1 := by
  have hlen := toRing_len p inj x
  have hslot : (p.toRing inj x).2.lifo.toList.length = p.lifo.toList.length := by
    simp only [Pool.toRing]
    split <;> rfl
  simp only [Pool.inFlight, Pool.contents, List.length_append] at ⊢
  rw [hslot]
  omega

/-- **Submission holds one more item**, full ring included, counting the overflow the shared list takes. -/
theorem submit_inFlight {p : Pool α} {x : α} (inj : List α) :
    (p.submit inj x).2.inFlight + (p.submit inj x).1.length = p.inFlight + inj.length + 1 := by
  simp only [Pool.submit]
  exact toRing_inFlight p inj x

/-- **A take off the ring holds one fewer item.** The count companion of `takeFromRing`: a successful take
removes exactly one, and the failure arm is the one that had nothing to remove. -/
theorem takeFromRing_inFlight {p : Pool α} (h : (p.takeFromRing).1.isSome) :
    (p.takeFromRing).2.inFlight + 1 = p.inFlight := by
  simp only [Pool.takeFromRing] at h ⊢
  cases hr : p.ring with
  | nil => simp [hr] at h
  | cons x rest =>
    simp only [hr, Pool.inFlight, Pool.contents, List.length_append, List.length_cons] at ⊢
    omega

/-- The slot's own take holds one fewer, when it took one. -/
theorem takeSlot_inFlight {p : Pool α} (h : (p.takeSlot).1.isSome) :
    (p.takeSlot).2.inFlight + 1 = p.inFlight := by
  simp only [Pool.takeSlot] at h ⊢
  by_cases hp : p.lifoPolls < p.lifoCap
  · rw [ite_eq_left hp] at h ⊢
    cases hl : p.lifo with
    | none => simp [hl] at h
    | some x =>
      simp only [hl, Pool.inFlight, Pool.contents, Option.toList_some, Option.toList_none,
        List.length_append, List.length_nil, List.length_singleton] at ⊢
  · rw [ite_eq_right hp] at h ⊢
    simp at h

/-- Clearing the slot holds one fewer, when there was one to clear. -/
theorem flushSlot_inFlight {p : Pool α} (h : (p.flushSlot).1.isSome) :
    (p.flushSlot).2.inFlight + 1 = p.inFlight := by
  simp only [Pool.flushSlot] at h ⊢
  cases hl : p.lifo with
  | none => simp [hl] at h
  | some x =>
    simp only [hl, Pool.inFlight, Pool.contents, Option.toList_some, Option.toList_none,
      List.length_append, List.length_nil, List.length_singleton] at ⊢

/-- **`take` holds one fewer item when it returned one.** Either way the decision went, exactly one leaves
the pool's own queue; the allowance's flush is the executor's separate clear, and its count is
`flushSlot_inFlight`. -/
theorem take_inFlight {p : Pool α} (h : (p.take).1.isSome) :
    (p.take).2.inFlight + 1 = p.inFlight := by
  simp only [Pool.take] at h ⊢
  by_cases hp : p.lifoPolls < p.lifoCap
  · rw [ite_eq_left hp] at h ⊢
    cases hl : p.lifo with
    | none   =>
      simp only [hl] at h
      exact takeFromRing_inFlight h
    | some x =>
      simp only [hl, Pool.inFlight, Pool.contents, Option.toList_some, Option.toList_none,
        List.length_append, List.length_nil, List.length_singleton] at ⊢
  · rw [ite_eq_right hp] at h ⊢
    exact takeFromRing_inFlight h

/-- **A successful steal holds one fewer**, the same law as the ring take it is defined as. -/
theorem steal_inFlight {p : Pool α} (h : (p.steal).1.isSome) : (p.steal).2.inFlight + 1 = p.inFlight :=
  takeFromRing_inFlight h

/-! ### Spawning

`spawn` is a write path too, and it gets the same pair of laws as `submit`. Without them the slot would
be a model field with a writer but no invariant, which is the shape of the defect found in the executor
this morning: a path that moves state the model describes, with nothing checking that it moved it
correctly. -/

/-- Spawn conserves work. The displaced task is placed, not dropped, and both it and the spawn were
already counted. -/
theorem spawn_conserves {p : Pool α} (x : α) (inj : List α) (h : p.Consistent inj) :
    (p.spawn inj x).2.Consistent (p.spawn inj x).1 := by
  simp only [Pool.Consistent, Pool.inFlight, Pool.contents, List.length_append] at h
  simp only [Pool.spawn]
  cases hl : p.lifo with
  | none =>
    simp only [hl, Pool.Consistent, Pool.inFlight, Pool.contents, Option.toList_some,
      Option.toList_none, List.length_append, List.length_nil, List.length_singleton] at h ⊢
    omega
  | some y =>
    simp only [Pool.toRing]
    by_cases hc : p.ring.length < p.cap
    · rw [ite_eq_left hc]
      simp only [hl, Pool.Consistent, Pool.inFlight, Pool.contents, Option.toList_some,
        List.length_append, List.length_singleton] at h ⊢
      omega
    · rw [ite_eq_right hc]
      simp only [hl, Pool.Consistent, Pool.inFlight, Pool.contents, Option.toList_some,
        List.length_append, List.length_singleton] at h ⊢
      have hsum := length_take_add_drop p.ring (p.ring.length / 2)
      omega

/-- Spawn keeps the ring bounded: the slot holds something, but the slot is not the ring. -/
theorem spawn_bounded {p : Pool α} {x : α} (inj : List α) (hb : p.Bounded) (hcap : 2 ≤ p.cap) :
    (p.spawn inj x).2.Bounded := by
  simp only [Pool.spawn]
  cases hl : p.lifo with
  | none   => simpa [hl, Pool.Bounded] using hb
  | some y => simpa [hl, Pool.Bounded] using toRing_bounded (p := p) (inj := inj) (x := y) hb hcap

/-- A spawn holds one more item, counting what it moved to the shared list. -/
theorem spawn_inFlight {p : Pool α} {x : α} (inj : List α) :
    (p.spawn inj x).2.inFlight + (p.spawn inj x).1.length = p.inFlight + inj.length + 1 := by
  simp only [Pool.spawn]
  cases hl : p.lifo with
  | none =>
    simp only [hl, Pool.inFlight, Pool.contents, Option.toList_some, Option.toList_none,
      List.length_append, List.length_nil, List.length_singleton] at ⊢
    omega
  | some y =>
    simp only [Pool.toRing]
    by_cases hc : p.ring.length < p.cap
    · rw [ite_eq_left hc]
      simp only [hl, Pool.inFlight, Pool.contents, Option.toList_some, List.length_append,
        List.length_singleton] at ⊢
      omega
    · rw [ite_eq_right hc]
      simp only [hl, Pool.inFlight, Pool.contents, Option.toList_some, List.length_append,
        List.length_singleton] at ⊢
      have hsum := length_take_add_drop p.ring (p.ring.length / 2)
      omega

/-! ### No work is stranded -/

/-- **A take off the ring returns something whenever the ring holds anything.** The ring's own arm, on the
one part of the worker's queue the pool can decide about alone. -/
theorem takeFromRing_returns_if_present {p : Pool α} (h : p.ring ≠ []) :
    (p.takeFromRing).1.isSome := by
  simp only [Pool.takeFromRing]
  cases hr : p.ring with
  | cons x rest => simp
  | nil => exact absurd hr h

/-- **`take` returns something whenever the ring holds anything.**

Holding work *only* in the LIFO slot is the one case this cannot promise: with the allowance spent, the slot
must be cleared for the shared inject before the ring is consulted, and that clear — and the list it lands in
— is the executor's, not this pool's. That is `flushSlot_returns_if_present` below, and `takeSlot` is what
says which case the pool is in. -/
theorem take_returns_if_present {p : Pool α} (h : p.ring ≠ []) : (p.take).1.isSome := by
  simp only [Pool.take]
  by_cases hp : p.lifoPolls < p.lifoCap
  · rw [ite_eq_left hp]
    cases hl : p.lifo with
    | some x => simp
    | none   => exact takeFromRing_returns_if_present h
  · rw [ite_eq_right hp]
    exact takeFromRing_returns_if_present h

/-- …and while the allowance lasts, the slot is served: the pool's other case. -/
theorem take_returns_if_slot_present {p : Pool α} (hp : p.lifoPolls < p.lifoCap) (hl : p.lifo.isSome) :
    (p.take).1.isSome := by
  simp only [Pool.take, ite_eq_left hp]
  cases hl' : p.lifo with
  | some x => simp
  | none   => simp [hl'] at hl

/-- **The flush returns the slot's task whenever the slot holds one.** The pool half of "the allowance
cannot strand work": once the executor decides to clear the slot, there is always something to hand it. -/
theorem flushSlot_returns_if_present {p : Pool α} (hl : p.lifo.isSome) : (p.flushSlot).1.isSome := by
  simp only [Pool.flushSlot]
  cases hl' : p.lifo with
  | some x => simp
  | none   => simp [hl'] at hl

/-- **The step's disjunction**: when the pool's own queue holds anything it either serves it or has something
to clear for the shared list. `HasWork` is the ring **or** the slot, and the two halves are the three lemmas
above — the ring by `take_returns_if_present`, the slot by `take_returns_if_slot_present` while the allowance
lasts and `flushSlot_returns_if_present` once it is spent. This is the pool-level statement the executor's
take step composes, and it is a corollary of the split rather than a restatement of it. -/
theorem take_or_flushSlot_returns_of_hasWork {p : Pool α} (h : p.HasWork) :
    (p.take).1.isSome ∨ (p.flushSlot).1.isSome := by
  rcases h with hr | hl
  · exact Or.inl (take_returns_if_present hr)
  · by_cases hp : p.lifoPolls < p.lifoCap
    · exact Or.inl (take_returns_if_slot_present hp hl)
    · exact Or.inr (flushSlot_returns_if_present hl)

/-- Stealing is the same claim for a thief, and it deliberately cannot see the LIFO slot — so work
held *only* in the slot is not stealable, which is the documented behaviour. The vacuity checks below
show that this is a real restriction and not vacuity. -/
theorem steal_returns_if_ring_nonempty {p : Pool α} (h : p.ring ≠ []) : (p.steal).1.isSome :=
  takeFromRing_returns_if_present h

/-! ### Vacuity checks

Each predicate must be shown to distinguish, or a theorem about it is true of everything and means
nothing. -/

/-- A fresh pool is consistent, with an empty shared list. -/
example : (emptyPool Nat).Consistent [] := by
  simp [Pool.Consistent, Pool.inFlight, Pool.contents, emptyPool]

/-- …and an inconsistent pool exists, so `Consistent` is not true of everything. -/
example : ¬ ({(emptyPool Nat) with pushed := 1}).Consistent [] := by
  simp [Pool.Consistent, Pool.inFlight, Pool.contents, emptyPool]

/-- An empty pool has no work… -/
example : ¬ (emptyPool Nat).HasWork := by simp [Pool.HasWork, emptyPool]

/-- …and a pool holding only a LIFO task has work — which is the case `steal` cannot reach. -/
example : ({(emptyPool Nat) with lifo := some 7}).HasWork := by
  simp [Pool.HasWork, emptyPool]

/-- The control for `steal`'s restriction: work in the LIFO slot alone is genuinely not stealable. -/
example : ({(emptyPool Nat) with lifo := some 7}).steal.1 = none := rfl

/-- The affirmative control for `take`: the owner *can* reach the slot that a thief cannot. -/
example : ({(emptyPool Nat) with lifo := some 7}).take.1 = some 7 := by
  simp [Pool.take, emptyPool]

/-- And the *shared* list is a real destination: the eviction is not the pool's, so a full-ring submit
leaves the pool holding less and the caller's list holding the difference. -/
example : (({(emptyPool Nat) with cap := 2, ring := [0, 1]}).submit [] 2).2.inFlight = 2 := by decide

/-- The control for the claim below: the same pool, before the flush, is consistent with the empty list —
so what the flush breaks is the composition, not a pool that was never consistent. -/
example : ({(emptyPool Nat) with lifo := some 7, pushed := 1}).Consistent [] := by
  simp [Pool.Consistent, Pool.inFlight, Pool.contents, emptyPool]

/-- **The flush's composition is load-bearing**: the pool's own count falls, and it is the *append* the
caller performs that keeps `Consistent`. A caller that dropped the cleared task would break the law — the
hypothesis `Consistent (inj ++ [x])` is what says so.

The literal carries `pushed := 1` because the flush *moves* an item the pool has already accepted: it changes
neither `inFlight` nor `taken`, so only a pool that already looks accepted — as the control above shows — can
exhibit the composition failing once the append is dropped. -/
example : ¬ (({(emptyPool Nat) with lifo := some 7, pushed := 1}).flushSlot.2.Consistent []) := by
  simp [Pool.flushSlot, Pool.Consistent, Pool.inFlight, Pool.contents, emptyPool]

/-! ### The audit

None of the model's theorems should rest on the bridge axioms — the pool is *about* the primitives, so
a proof that depended on one would be circular. `#print axioms` is the check. -/

#print axioms LeanIn.Model.take_returns_if_present
#print axioms LeanIn.Model.submit_conserves
#print axioms LeanIn.Model.submit_bounded
#print axioms LeanIn.Model.toRing_len
#print axioms LeanIn.Model.toRing_inFlight
#print axioms LeanIn.Model.spawn_conserves
#print axioms LeanIn.Model.spawn_bounded
#print axioms LeanIn.Model.take_conserves
#print axioms LeanIn.Model.takeSlot_conserves
#print axioms LeanIn.Model.flushSlot_conserves
#print axioms LeanIn.Model.flushSlot_returns_if_present
#print axioms LeanIn.Model.take_inFlight
#print axioms LeanIn.Model.takeFromRing_inFlight
#print axioms LeanIn.Model.spawn_inFlight

end Model

end LeanIn
