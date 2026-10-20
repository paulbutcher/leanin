module

public import LeanIn.Model.Inject
public import LeanIn.Model.Pool
public import LeanIn.Model.Scheduler


public section
/-!
# The model at P carriers

`LeanIn.Model.Pool` is one carrier's queue — a ring and a LIFO slot — and `LeanIn.Model.Scheduler` is the
wake protocol abstracted to counts. This file is the layer between them: P carriers, each holding a pool,
sharing one inject, with the park flags that say who is waiting. `Multi.toSched` projects it onto
`Sched`, so the single-carrier statement is a corollary of the multi-carrier one rather than a second
statement.

## What is shared and what is not

A carrier's ring and its LIFO slot are written by that carrier alone, under its own lock. The **inject is
shared by every carrier**, and so are the park flags and the two totals, which is why `Pool` holds no
inject: `Pool.inFlight` is what one carrier's own queue holds, while the global count `Multi.held` is the
sum of every carrier's `inFlight` plus the shared list. The shared list's own laws are
`LeanIn.Model.Inject`'s; the **global conservation law over the composition is `Multi.Consistent`**, and
`Pool.Consistent` is one carrier's own part of it.

The park flags are why this structure exists rather than a count: a *carrier-level* wake is about which
carrier parked, not only how many. `Multi.Live` states the obligation as a count, because that is what
the protocol cares about, but the invariants the count is derived from are per carrier.

## The three obligations, and the invariants they ride on

* **No lost wakeup** — `reachable_live`: if work is held, some carrier is not parked.
* **No lost work** — `reachable_consistent`: everything submitted is held or was taken, the steal
  included — a thief's item leaves the victim's ring and is counted as taken.
* **Bounded work per tick** — `reachable_bound`: every carrier's allowance stays within its own limit,
  `tick i` refreshes only carrier `i`'s, and a spent allowance cannot strand the slot
  (`takeStep_returns_if_present`).

`Multi.Live` is derived from two invariants rather than proved step by step, because work reaches the
queue by more than one route:

* `Multi.ZeroParked` — a parked carrier holds nothing in its own pool. It is what turns "some carrier
  holds work" into "that carrier is not parked".
* `Multi.InjectWatched` — a non-empty shared list implies some carrier is not parked. A local push that
  overflows, and `flushLocal`, both put work in the shared list without un-parking anyone: the carrier
  that pushed is by construction not parked, and this records it.

Only a carrier writes its own pool, and it clears its own pool before parking — the model form of the
implementation's argument that a carrier's queue can receive work from nobody but itself, while every
arrival in the shared list comes from a carrier that is running. `flushLocal` therefore owes no wake of
its own.
-/

namespace LeanIn

namespace Model

/-- The model at P carriers: one pool per carrier, the shared inject, and one park flag per carrier. -/
structure Multi (α : Type) (cap : Nat) where
  /-- One pool per carrier; inject-free, because the inject is shared. -/
  workers  : List (Pool α) := []
  /-- The shared list: external wakes, and every carrier's overflow and flush. -/
  inject   : Inject α := { items := [] }
  /-- One flag per carrier, which is what a carrier-level wake is about. -/
  parked   : List Bool := []
  /-- Set by `stop`. -/
  stopping : Bool := false
  /-- Everything submitted to the composition. -/
  pushed   : Nat := 0
  /-- Everything taken from the composition, by an owner or by a thief. -/
  taken    : Nat := 0

/-! ### List plumbing

The carriers and their flags are parallel lists, so a step writes one position of each. `setAt` does
that and leaves the length and every other position alone, which is what lets an index survive a step. -/

/-- Set position `i`, preserving the length and every other position; out of range, the list is
unchanged. -/
def setAt {β : Type} (l : List β) (i : Nat) (b : β) : List β :=
  match l with
  | [] => []
  | a :: rest =>
    match i with
    | 0 => b :: rest
    | n + 1 => a :: setAt rest n b

/-- Clear the first set flag: `pushShared`'s wake, one parked carrier un-parked. It only ever writes
`false`, which is why every position it touches is a carrier that is running. -/
def unparkOne : List Bool → List Bool
  | [] => []
  | true :: bs => false :: bs
  | false :: bs => false :: unparkOne bs

theorem setAt_length {β : Type} (l : List β) (i : Nat) (b : β) :
    (setAt l i b).length = l.length := by
  induction l generalizing i with
  | nil => rfl
  | cons a rest ih => cases i with
    | zero => rfl
    | succ i' =>
      have ih' := ih i'
      simp only [setAt, List.length_cons]
      omega

theorem length_of_getElem? {l : List β} {i : Nat} {b : β} (h : l[i]? = some b) : i < l.length := by
  induction l generalizing i with
  | nil => simp at h
  | cons a rest ih => cases i with
    | zero => simp
    | succ i' => simpa only [List.length_cons, Nat.succ_lt_succ_iff] using ih (by simpa using h)

/-- A position that reads as `some b` is a position `b` occurs at. -/
theorem mem_of_getElem? {l : List β} {i : Nat} {b : β} (h : l[i]? = some b) : b ∈ l := by
  have h1 := List.getElem?_eq_some_iff.mp h
  rw [← h1.2]
  exact List.getElem_mem h1.1

theorem getElem?_setAt_self {l : List β} {i : Nat} {b : β} (h : i < l.length) :
    (setAt l i b)[i]? = some b := by
  induction l generalizing i with
  | nil => simp at h
  | cons a rest ih => cases i with
    | zero => rfl
    | succ i' =>
      have h' : i' < rest.length := by simpa only [List.length_cons, Nat.succ_lt_succ_iff] using h
      simpa only [setAt, List.getElem?_cons_succ] using ih h'

theorem getElem?_setAt_ne {l : List β} {i j : Nat} {b : β} (h : i ≠ j) :
    (setAt l i b)[j]? = l[j]? := by
  induction l generalizing i j with
  | nil => rfl
  | cons a rest ih => cases i with
    | zero => cases j with
      | zero => exact absurd rfl h
      | succ j' => rfl
    | succ i' => cases j with
      | zero => rfl
      | succ j' =>
        have h' : i' ≠ j' := fun hh => h (by rw [hh])
        simpa only [setAt, List.getElem?_cons_succ] using ih h'

theorem mem_setAt {b : β} {l : List β} {i : Nat} {a : β} (h : b ∈ setAt l i a) : b = a ∨ b ∈ l := by
  induction l generalizing i with
  | nil => simp [setAt] at h
  | cons c rest ih => cases i with
    | zero =>
      have h' : b ∈ (a :: rest) := by simpa only [setAt] using h
      rcases List.mem_cons.mp h' with h | h
      · exact Or.inl h
      · exact Or.inr (List.mem_cons.mpr (Or.inr h))
    | succ i' =>
      have h' : b ∈ (c :: setAt rest i' a) := by simpa only [setAt] using h
      rcases List.mem_cons.mp h' with h | h
      · exact Or.inr (List.mem_cons.mpr (Or.inl h))
      · rcases ih h with h'' | h''
        · exact Or.inl h''
        · exact Or.inr (List.mem_cons.mpr (Or.inr h''))

theorem unparkOne_length (bs : List Bool) : (unparkOne bs).length = bs.length := by
  induction bs with
  | nil => rfl
  | cons b rest ih => cases b <;> simp only [unparkOne, List.length_cons, ih]

theorem unparkOne_getElem?_true {bs : List Bool} {j : Nat} (h : (unparkOne bs)[j]? = some true) :
    bs[j]? = some true := by
  induction bs generalizing j with
  | nil => simp [unparkOne] at h
  | cons b rest ih => cases j with
    | zero => cases b <;> simp [unparkOne] at h
    | succ j' =>
      cases b with
      | true => simpa only [unparkOne, List.getElem?_cons_succ] using h
      | false =>
        have h' : (unparkOne rest)[j']? = some true := by
          simpa only [unparkOne, List.getElem?_cons_succ] using h
        simpa only [List.getElem?_cons_succ] using ih h'

theorem unparkOne_getElem?_zero : ∀ bs : List Bool, ((unparkOne bs)[0]?).getD false = false
  | [] => rfl
  | true :: _ => rfl
  | false :: _ => rfl

theorem option_eq_some_true_of_getD {o : Option Bool} (h : o.getD false = true) : o = some true := by
  cases o with
  | none => simp at h
  | some b => cases b <;> simp_all

theorem toList_length_of_isSome {o : Option α} (h : o.isSome) : o.toList.length = 1 := by
  cases o with
  | none => simp at h
  | some a => rfl

/-- The fresh flags are all clear, so no position among them reads as parked. -/
theorem replicate_false_get (n : Nat) (i : Nat) :
    ((List.replicate n false)[i]?).getD false = false := by
  induction n generalizing i with
  | zero => cases i <;> rfl
  | succ n ih => cases i with
    | zero => rfl
    | succ i' => simpa only [List.replicate_succ, List.getElem?_cons_succ] using ih i'

theorem filter_id_length_le (l : List Bool) : (l.filter id).length ≤ l.length :=
  List.length_filter_le id l

/-- Every flag is set when the filtered count has caught up with the length. -/
theorem all_true_of_filter_id_length_eq {l : List Bool} (h : (l.filter id).length = l.length) :
    ∀ b ∈ l, b = true := by
  induction l with
  | nil => simp
  | cons c rest ih =>
    have hc : c = true := by
      cases c with
      | true => rfl
      | false =>
        exfalso
        simp only [List.filter_cons_of_neg (p := id) (a := false) (by decide),
          List.length_cons] at h
        have := List.length_filter_le id rest
        omega
    have hrest : (rest.filter id).length = rest.length := by
      have h1 : (List.filter id (true :: rest)).length = (true :: rest).length := by
        simpa only [hc] using h
      simp only [List.filter_cons_of_pos (p := id) (a := true) (by decide), List.length_cons,
        Nat.add_right_cancel_iff] at h1
      exact h1
    intro b hb
    rcases List.mem_cons.mp hb with rfl | hb
    · exact hc
    · exact ih hrest b hb

theorem sum_eq_zero_of_forall_getElem {β : Type} (l : List β) (f : β → Nat)
    (h : ∀ (i : Nat) (hi : i < l.length), f l[i] = 0) : (l.map f).sum = 0 := by
  induction l with
  | nil => rfl
  | cons a rest ih =>
    have ha : f a = 0 := h 0 (by simp)
    have hrest : (rest.map f).sum = 0 := by
      refine ih ?_
      intro i hi
      have hsucc : i + 1 < (a :: rest).length := by simp only [List.length_cons]; omega
      have h' := h (i + 1) hsucc
      rw [List.getElem_cons_succ a rest i hsucc] at h'
      exact h'
    simp only [List.map_cons, List.sum_cons, ha, hrest, Nat.add_zero]

/-- Replacing one entry moves the sum by the difference of the two entries, added to both sides so the
arithmetic never has to see a subtraction. -/
theorem sum_map_setAt {β : Type} (l : List β) (f : β → Nat) {i : Nat} {a b : β}
    (h : l[i]? = some a) :
    ((setAt l i b).map f).sum + f a = (l.map f).sum + f b := by
  induction l generalizing i a with
  | nil => simp at h
  | cons c rest ih => cases i with
    | zero =>
      have ha : a = c := by simpa using h.symm
      subst ha
      simp only [setAt, List.map_cons, List.sum_cons]
      omega
    | succ i' =>
      have h' : rest[i']? = some a := by simpa using h
      have := ih h'
      simp only [setAt, List.map_cons, List.sum_cons]
      omega

theorem sum_replicate_zero (n : Nat) : (List.replicate n (0 : Nat)).sum = 0 := by
  induction n with
  | zero => rfl
  | succ n ih => simp only [List.replicate_succ, List.sum_cons, ih, Nat.add_zero]

/-! ### Reading the state -/

/-- Whether position `i` is parked; out of range counts as not parked. -/
def Multi.parkedAt (m : Multi α cap) (i : Nat) : Bool := (m.parked[i]?).getD false

/-- How many carriers are parked. -/
def Multi.parkedCount (m : Multi α cap) : Nat := (m.parked.filter id).length

/-- Everything held: every carrier's own queue, plus the shared list. -/
@[expose] def Multi.held (m : Multi α cap) : Nat :=
  (m.workers.map Pool.inFlight).sum + m.inject.items.length

/-- **The projection onto the abstract protocol.** `work` is the composition's `held`, `parked` is how
many carriers are parked, `total` is how many there are; this is what the single-carrier statement is
re-read against. -/
def Multi.toSched (m : Multi α cap) : Sched :=
  { work := m.held
    parked := m.parkedCount
    total := m.workers.length
    stopping := m.stopping }

/-- Well-formedness: at least one carrier, one flag per carrier, and every carrier's capacity is the
type parameter's. The flags' alignment is what lets a position mean the same carrier in both lists. -/
@[expose] def Multi.WF (m : Multi α cap) : Prop :=
  0 < m.workers.length ∧ m.parked.length = m.workers.length ∧ ∀ p ∈ m.workers, p.cap = cap

/-- **No lost wakeup**, in the shape the single-carrier obligation has: either nothing is held, or some
carrier is not parked. -/
@[expose] def Multi.Live (m : Multi α cap) : Prop :=
  m.held = 0 ∨ m.parkedCount < m.workers.length

/-- **No lost work**: everything submitted is held or was taken. -/
def Multi.Consistent (m : Multi α cap) : Prop := m.held + m.taken = m.pushed

/-- A parked carrier holds nothing in its own pool. -/
def Multi.ZeroParked (m : Multi α cap) : Prop :=
  ∀ i p, m.workers[i]? = some p → m.parkedAt i = true → p.inFlight = 0

/-- A non-empty shared list implies some carrier is not parked — the invariant `ZeroParked` does not
give, because a flush and a local overflow both add to the shared list without un-parking anyone. -/
def Multi.InjectWatched (m : Multi α cap) : Prop :=
  m.inject.items ≠ [] → ∃ i, i < m.workers.length ∧ m.parkedAt i = false

/-- **Bounded work per tick**: every carrier's allowance is within its own limit. -/
def Multi.Bounded (m : Multi α cap) : Prop := ∀ p ∈ m.workers, p.lifoPolls ≤ p.lifoCap

/-- A fresh composition: `n` carriers, all empty, none parked, nothing held, every carrier's own
capacity the type parameter's. -/
@[expose] def Multi.initial (α : Type) (cap : Nat) (n : Nat) : Multi α cap :=
  { workers := List.replicate n { emptyPool α with cap := cap }
    inject := { items := [] }
    parked := List.replicate n false }

/-! ### What a pool's own operations leave alone

The invariants below are about the carrier list, so they need to know which fields a pool's own
operations write: neither `cap` nor `lifoCap` (the type parameter's and the allowance's limits) is
touched by a placement or a take, and a tick resets the allowance while leaving the counts alone. -/

theorem submit_cap (p : Pool α) (inj : List α) (x : α) : (p.submit inj x).2.cap = p.cap := by
  dsimp only [Pool.submit, Pool.toRing]
  split <;> rfl

theorem submit_lifoCap (p : Pool α) (inj : List α) (x : α) :
    (p.submit inj x).2.lifoCap = p.lifoCap := by
  dsimp only [Pool.submit, Pool.toRing]
  split <;> rfl

theorem submit_lifoPolls (p : Pool α) (inj : List α) (x : α) :
    (p.submit inj x).2.lifoPolls = p.lifoPolls := by
  dsimp only [Pool.submit, Pool.toRing]
  split <;> rfl

theorem spawn_cap (p : Pool α) (inj : List α) (x : α) : (p.spawn inj x).2.cap = p.cap := by
  dsimp only [Pool.spawn, Pool.toRing]
  split <;> (first | rfl | (split <;> rfl))

theorem spawn_lifoCap (p : Pool α) (inj : List α) (x : α) :
    (p.spawn inj x).2.lifoCap = p.lifoCap := by
  dsimp only [Pool.spawn, Pool.toRing]
  split <;> (first | rfl | (split <;> rfl))

theorem spawn_lifoPolls (p : Pool α) (inj : List α) (x : α) :
    (p.spawn inj x).2.lifoPolls = p.lifoPolls := by
  dsimp only [Pool.spawn, Pool.toRing]
  split <;> (first | rfl | (split <;> rfl))

theorem takeFromRing_cap (p : Pool α) : (p.takeFromRing).2.cap = p.cap := by
  dsimp only [Pool.takeFromRing]
  split <;> rfl

theorem takeFromRing_lifoCap (p : Pool α) : (p.takeFromRing).2.lifoCap = p.lifoCap := by
  dsimp only [Pool.takeFromRing]
  split <;> rfl

theorem takeFromRing_lifoPolls (p : Pool α) : (p.takeFromRing).2.lifoPolls = p.lifoPolls := by
  dsimp only [Pool.takeFromRing]
  split <;> rfl

theorem flushSlot_cap (p : Pool α) : (p.flushSlot).2.cap = p.cap := by
  dsimp only [Pool.flushSlot]
  split <;> rfl

theorem flushSlot_lifoCap (p : Pool α) : (p.flushSlot).2.lifoCap = p.lifoCap := by
  dsimp only [Pool.flushSlot]
  split <;> rfl

theorem flushSlot_lifoPolls (p : Pool α) : (p.flushSlot).2.lifoPolls = p.lifoPolls := by
  dsimp only [Pool.flushSlot]
  split <;> rfl

theorem take_cap (p : Pool α) : (p.take).2.cap = p.cap := by
  dsimp only [Pool.take, Pool.takeFromRing]
  split <;> (first | rfl | (split <;> (first | rfl | (split <;> rfl))))

theorem take_lifoCap (p : Pool α) : (p.take).2.lifoCap = p.lifoCap := by
  dsimp only [Pool.take, Pool.takeFromRing]
  split <;> (first | rfl | (split <;> (first | rfl | (split <;> rfl))))

theorem take_lifoPolls_le (p : Pool α) (h : p.lifoPolls ≤ p.lifoCap) :
    (p.take).2.lifoPolls ≤ (p.take).2.lifoCap := by
  dsimp only [Pool.take, Pool.takeFromRing]
  split <;> (try split) <;> (try split) <;> dsimp only <;> omega

theorem tick_cap (p : Pool α) : (p.tick).cap = p.cap := rfl

theorem tick_lifoCap (p : Pool α) : (p.tick).lifoCap = p.lifoCap := rfl

theorem tick_lifoPolls (p : Pool α) : (p.tick).lifoPolls = 0 := rfl

theorem tick_inFlight (p : Pool α) : (p.tick).inFlight = p.inFlight := rfl

/-! ### The transitions

Every premise a step needs is checked inside the step, so the reachability relation carries an equality
rather than a side condition. `pushShared` is the one step with no premise: the shared list is
unbounded, and the wake is part of the step. -/

/-- **A local push, the ring lane.** The carrier is not parked, and the task joins its own queue by the
placement rule — ring, overflow to the shared list — with the shared list threaded through. -/
def Multi.pushLocal (m : Multi α cap) (i : Nat) (x : α) : Option (Multi α cap) :=
  match m.workers[i]? with
  | none => none
  | some p =>
    if m.parkedAt i = false then
      some { m with workers := setAt m.workers i (p.submit m.inject.items x).2,
                    inject := { items := (p.submit m.inject.items x).1 },
                    pushed := m.pushed + 1 }
    else none

/-- **A local push, the LIFO lane.** The same premise and the same count, with the task taking the slot
and the task it displaces going through the placement rule. -/
def Multi.spawnLocal (m : Multi α cap) (i : Nat) (x : α) : Option (Multi α cap) :=
  match m.workers[i]? with
  | none => none
  | some p =>
    if m.parkedAt i = false then
      some { m with workers := setAt m.workers i (p.spawn m.inject.items x).2,
                    inject := { items := (p.spawn m.inject.items x).1 },
                    pushed := m.pushed + 1 }
    else none

/-- **Clear a carrier's slot into the shared list.** The item was counted when it entered the pool, so
`held`, `pushed` and `taken` all stay where they are — a flush re-queues, it does not serve. -/
def Multi.flushLocal (m : Multi α cap) (i : Nat) : Option (Multi α cap) :=
  match m.workers[i]? with
  | none => none
  | some p =>
    if m.parkedAt i = false then
      if (p.flushSlot).1.isSome then
        some { m with workers := setAt m.workers i (p.flushSlot).2,
                      inject := { items := m.inject.items ++ (p.flushSlot).1.toList } }
      else none
    else none

/-- **A push into the shared list, with the wake in the same step.** The append and the un-parking are
not separable: a notification has no memory, so one that lands before the carrier parks is lost. -/
def Multi.pushShared (m : Multi α cap) (x : α) : Multi α cap :=
  { m with inject := m.inject.push x, parked := unparkOne m.parked, pushed := m.pushed + 1 }

/-- **A carrier's own take**, from its own queue: the slot while the tick's allowance lasts, else the
ring. The shared list is the layer's fallback, not this pool's, so the carrier's whole step is
`takeStep_returns_if_present` rather than this function alone. -/
def Multi.takeLocal (m : Multi α cap) (i : Nat) : Option (Multi α cap) :=
  match m.workers[i]? with
  | none => none
  | some p =>
    if (p.take).1.isSome then
      some { m with workers := setAt m.workers i (p.take).2, taken := m.taken + 1 }
    else none

/-- **A take from the shared list**, from the front. -/
def Multi.takeShared (m : Multi α cap) : Option (Multi α cap) :=
  if (m.inject.pop).1.isSome then
    some { m with inject := (m.inject.pop).2, taken := m.taken + 1 }
  else none

/-- **A steal.** Carrier `i` removes one element from carrier `j`'s ring and takes it: the item leaves
the victim's ring, `held` falls by one and `taken` rises by one, so the conserved sum does not move. The
slot is not reachable from here, and the thief gains nothing in its own queue. -/
def Multi.stealInto (m : Multi α cap) (i j : Nat) : Option (Multi α cap) :=
  if i = j then none
  else
    match m.workers[j]? with
    | none => none
    | some pv =>
      match m.workers[i]? with
      | none => none
      | some _ =>
        if (pv.takeFromRing).1.isSome then
          some { m with workers := setAt m.workers j (pv.takeFromRing).2, taken := m.taken + 1 }
        else none

/-- **A carrier parks.** Only from its own empty queue *and* an empty shared list, so the check and the
park are one step and nothing can arrive between them. -/
@[expose] def Multi.park (m : Multi α cap) (i : Nat) : Option (Multi α cap) :=
  match m.workers[i]? with
  | none => none
  | some p =>
    if p.inFlight = 0 then
      if m.inject.items = [] then
        if m.parkedAt i = false then
          some { m with parked := setAt m.parked i true }
        else none
      else none
    else none

/-- A tick at one carrier: its allowance refreshes and nothing else moves. -/
def Multi.tick (m : Multi α cap) (i : Nat) : Multi α cap :=
  match m.workers[i]? with
  | none => m
  | some p => { m with workers := setAt m.workers i p.tick }

/-- Shutdown. -/
@[expose] def Multi.stop (m : Multi α cap) : Multi α cap := { m with stopping := true }

/-! ### The generic invariant steps

Each step changes at most one carrier's pool and the parked list, so its effect on the invariants is
stated once here and instantiated by the steps below. -/

theorem held_setWorker {m : Multi α cap} {i : Nat} {p q : Pool α} (hp : m.workers[i]? = some p) :
    ({ m with workers := setAt m.workers i q } : Multi α cap).held + p.inFlight
      = m.held + q.inFlight := by
  have hsum := sum_map_setAt (l := m.workers) (f := Pool.inFlight) (b := q) hp
  simp only [Multi.held]
  omega

theorem wf_setWorker {m : Multi α cap} (h : m.WF) {i : Nat} {q : Pool α} (hq : q.cap = cap) :
    ({ m with workers := setAt m.workers i q } : Multi α cap).WF := by
  obtain ⟨hpos, hlen, hcap⟩ := h
  refine ⟨?_, ?_, ?_⟩
  · simpa only [setAt_length] using hpos
  · simpa only [setAt_length] using hlen
  · intro r hr
    rcases mem_setAt hr with rfl | hr'
    · exact hq
    · exact hcap r hr'

theorem zeroParked_setWorker {m : Multi α cap} (h : m.ZeroParked) {i : Nat} {p q : Pool α}
    (hp : m.workers[i]? = some p) (hflag : m.parkedAt i = false ∨ q.inFlight = 0) :
    ({ m with workers := setAt m.workers i q } : Multi α cap).ZeroParked := by
  intro j r hj hq
  by_cases hji : j = i
  · subst j
    have hlt : i < m.workers.length := length_of_getElem? hp
    have hself := getElem?_setAt_self (l := m.workers) (i := i) (b := q) hlt
    rw [hself] at hj
    have hr : r = q := (Option.some.inj hj).symm
    rw [hr]
    rcases hflag with hf | hf
    · have hbad : m.parkedAt i = true := hq
      rw [hf] at hbad
      exact absurd hbad (by simp)
    · exact hf
  · have hne : i ≠ j := fun hh => hji hh.symm
    rw [getElem?_setAt_ne (l := m.workers) (i := i) (j := j) (b := q) hne] at hj
    exact h j r hj hq

theorem injectWatched_setWorker {m : Multi α cap} (h : m.InjectWatched) {i : Nat} {q : Pool α} :
    ({ m with workers := setAt m.workers i q } : Multi α cap).InjectWatched := by
  intro hinj
  obtain ⟨j, hj, hf⟩ := h hinj
  exact ⟨j, by simpa only [setAt_length] using hj, hf⟩

theorem bounded_setWorker {m : Multi α cap} (h : m.Bounded) {i : Nat} {q : Pool α}
    (hq : q.lifoPolls ≤ q.lifoCap) :
    ({ m with workers := setAt m.workers i q } : Multi α cap).Bounded := by
  intro r hr
  rcases mem_setAt hr with rfl | hr'
  · exact hq
  · exact h r hr'

/-! ### What each step is

One lemma per step, stating the case it took and producing the successor, so no later proof has to
re-derive the guard. -/

theorem pushLocal_spec {m m' : Multi α cap} {i : Nat} {x : α} (hs : m.pushLocal i x = some m') :
    ∃ p, m.workers[i]? = some p ∧ m.parkedAt i = false
      ∧ m' = { m with workers := setAt m.workers i (p.submit m.inject.items x).2,
                      inject := { items := (p.submit m.inject.items x).1 },
                      pushed := m.pushed + 1 } := by
  unfold Multi.pushLocal at hs
  split at hs
  · exact absurd hs (by simp)
  · rename_i p hp
    split at hs
    · rename_i hnp
      simp only [Option.some.injEq] at hs
      exact ⟨p, hp, hnp, hs.symm⟩
    · exact absurd hs (by simp)

theorem spawnLocal_spec {m m' : Multi α cap} {i : Nat} {x : α} (hs : m.spawnLocal i x = some m') :
    ∃ p, m.workers[i]? = some p ∧ m.parkedAt i = false
      ∧ m' = { m with workers := setAt m.workers i (p.spawn m.inject.items x).2,
                      inject := { items := (p.spawn m.inject.items x).1 },
                      pushed := m.pushed + 1 } := by
  unfold Multi.spawnLocal at hs
  split at hs
  · exact absurd hs (by simp)
  · rename_i p hp
    split at hs
    · rename_i hnp
      simp only [Option.some.injEq] at hs
      exact ⟨p, hp, hnp, hs.symm⟩
    · exact absurd hs (by simp)

theorem flushLocal_spec {m m' : Multi α cap} {i : Nat} (hs : m.flushLocal i = some m') :
    ∃ p, m.workers[i]? = some p ∧ m.parkedAt i = false ∧ (p.flushSlot).1.isSome
      ∧ m' = { m with workers := setAt m.workers i (p.flushSlot).2,
                      inject := { items := m.inject.items ++ (p.flushSlot).1.toList } } := by
  unfold Multi.flushLocal at hs
  split at hs
  · exact absurd hs (by simp)
  · rename_i p hp
    split at hs
    · rename_i hnp
      split at hs
      · rename_i hf
        simp only [Option.some.injEq] at hs
        exact ⟨p, hp, hnp, hf, hs.symm⟩
      · exact absurd hs (by simp)
    · exact absurd hs (by simp)

theorem takeLocal_spec {m m' : Multi α cap} {i : Nat} (hs : m.takeLocal i = some m') :
    ∃ p, m.workers[i]? = some p ∧ (p.take).1.isSome
      ∧ m' = { m with workers := setAt m.workers i (p.take).2, taken := m.taken + 1 } := by
  unfold Multi.takeLocal at hs
  split at hs
  · exact absurd hs (by simp)
  · rename_i p hp
    split at hs
    · rename_i ht
      simp only [Option.some.injEq] at hs
      exact ⟨p, hp, ht, hs.symm⟩
    · exact absurd hs (by simp)

theorem takeShared_spec {m m' : Multi α cap} (hs : m.takeShared = some m') :
    (m.inject.pop).1.isSome
      ∧ m' = { m with inject := (m.inject.pop).2, taken := m.taken + 1 } := by
  unfold Multi.takeShared at hs
  split at hs
  · rename_i hp
    simp only [Option.some.injEq] at hs
    exact ⟨hp, hs.symm⟩
  · exact absurd hs (by simp)

theorem stealInto_spec {m m' : Multi α cap} {i j : Nat} (hs : m.stealInto i j = some m') :
    ∃ pv, i ≠ j ∧ m.workers[j]? = some pv ∧ (pv.takeFromRing).1.isSome
      ∧ m' = { m with workers := setAt m.workers j (pv.takeFromRing).2, taken := m.taken + 1 } := by
  unfold Multi.stealInto at hs
  split at hs
  · exact absurd hs (by simp)
  · rename_i hij
    split at hs
    · exact absurd hs (by simp)
    · rename_i pv hpv
      split at hs
      · exact absurd hs (by simp)
      · split at hs
        · rename_i hsome
          simp only [Option.some.injEq] at hs
          exact ⟨pv, hij, hpv, hsome, hs.symm⟩
        · exact absurd hs (by simp)

theorem park_spec {m m' : Multi α cap} {i : Nat} (hs : m.park i = some m') :
    ∃ p, m.workers[i]? = some p ∧ p.inFlight = 0 ∧ m.inject.items = [] ∧ m.parkedAt i = false
      ∧ m' = { m with parked := setAt m.parked i true } := by
  unfold Multi.park at hs
  split at hs
  · exact absurd hs (by simp)
  · rename_i p hp
    split at hs
    · rename_i h1
      split at hs
      · rename_i h2
        split at hs
        · rename_i h3
          simp only [Option.some.injEq] at hs
          exact ⟨p, hp, h1, h2, h3, hs.symm⟩
        · exact absurd hs (by simp)
      · exact absurd hs (by simp)
    · exact absurd hs (by simp)

/-! ### What each step does to the count

The conservation law's per-step arithmetic, stated once here so that every invariant below can read the
count off the step instead of re-deriving it. Each is `Multi.held` against one pool's own count law. -/

theorem held_pushLocal {m m' : Multi α cap} {i : Nat} {x : α}
    (hs : m.pushLocal i x = some m') : m'.held = m.held + 1 := by
  obtain ⟨p, hp, _, heq⟩ := pushLocal_spec hs
  rw [heq]
  have hsum := sum_map_setAt (l := m.workers) (f := Pool.inFlight)
    (b := (p.submit m.inject.items x).2) hp
  have hpool := submit_inFlight (p := p) (x := x) (inj := m.inject.items)
  simp only [Multi.held] at hsum ⊢
  omega

theorem held_spawnLocal {m m' : Multi α cap} {i : Nat} {x : α}
    (hs : m.spawnLocal i x = some m') : m'.held = m.held + 1 := by
  obtain ⟨p, hp, _, heq⟩ := spawnLocal_spec hs
  rw [heq]
  have hsum := sum_map_setAt (l := m.workers) (f := Pool.inFlight)
    (b := (p.spawn m.inject.items x).2) hp
  have hpool := spawn_inFlight (p := p) (x := x) (inj := m.inject.items)
  simp only [Multi.held] at hsum ⊢
  omega

theorem held_flushLocal {m m' : Multi α cap} {i : Nat} (hs : m.flushLocal i = some m') :
    m'.held = m.held := by
  obtain ⟨p, hp, _, hsome, heq⟩ := flushLocal_spec hs
  rw [heq]
  have hsum := sum_map_setAt (l := m.workers) (f := Pool.inFlight) (b := (p.flushSlot).2) hp
  have hpool := flushSlot_inFlight (p := p) hsome
  have hlen := toList_length_of_isSome hsome
  simp only [Multi.held, List.length_append, hlen] at hsum ⊢
  omega

theorem held_pushShared (m : Multi α cap) (x : α) : (m.pushShared x).held = m.held + 1 := by
  have hlen := push_length m.inject x
  simp only [Multi.held, Multi.pushShared] at hlen ⊢
  omega

theorem held_takeLocal {m m' : Multi α cap} {i : Nat} (hs : m.takeLocal i = some m') :
    m'.held + 1 = m.held := by
  obtain ⟨p, hp, ht, heq⟩ := takeLocal_spec hs
  rw [heq]
  have hsum := sum_map_setAt (l := m.workers) (f := Pool.inFlight) (b := (p.take).2) hp
  have hpool := take_inFlight (p := p) ht
  simp only [Multi.held] at hsum ⊢
  omega

theorem held_takeShared {m m' : Multi α cap} (hs : m.takeShared = some m') :
    m'.held + 1 = m.held := by
  obtain ⟨hsome, heq⟩ := takeShared_spec hs
  rw [heq]
  have hlen : (m.inject.pop).2.items.length + 1 = m.inject.items.length := by
    cases hp : m.inject.items with
    | nil => simp [Inject.pop, hp] at hsome
    | cons y rest => simp [Inject.pop, hp]
  simp only [Multi.held]
  omega

theorem held_stealInto {m m' : Multi α cap} {i j : Nat} (hs : m.stealInto i j = some m') :
    m'.held + 1 = m.held := by
  obtain ⟨pv, _, hpv, hsome, heq⟩ := stealInto_spec hs
  rw [heq]
  have hsum := sum_map_setAt (l := m.workers) (f := Pool.inFlight) (b := (pv.takeFromRing).2) hpv
  have hpool := takeFromRing_inFlight (p := pv) hsome
  simp only [Multi.held] at hsum ⊢
  omega

theorem held_park {m m' : Multi α cap} {i : Nat} (hs : m.park i = some m') :
    m'.held = m.held := by
  obtain ⟨p, hp, _, _, _, heq⟩ := park_spec hs
  rw [heq]
  rfl

theorem held_tick_at {m : Multi α cap} {i : Nat} {p : Pool α} (hw : m.workers[i]? = some p) :
    ({ m with workers := setAt m.workers i p.tick } : Multi α cap).held = m.held := by
  have hsum := sum_map_setAt (l := m.workers) (f := Pool.inFlight) (b := p.tick) hw
  have hpool := tick_inFlight p
  simp only [Multi.held] at hsum ⊢
  omega

theorem held_stop (m : Multi α cap) : m.stop.held = m.held := rfl

/-! ### Reachability, and the invariants it preserves

"Reachable" is the right strength here as it is at one carrier: `Live` is not claimed of an arbitrary
well-formed state — a state with work and every carrier parked is well-formed and would be a lost
wakeup — only of the states the protocol can produce. -/

inductive Multi.Reachable : Multi α cap → Prop where
  | init (n : Nat) (h : 0 < n) : Reachable (Multi.initial α cap n)
  | pushLocal {m m' : Multi α cap} (h : Reachable m) (i : Nat) (x : α)
      (hs : m.pushLocal i x = some m') : Reachable m'
  | spawnLocal {m m' : Multi α cap} (h : Reachable m) (i : Nat) (x : α)
      (hs : m.spawnLocal i x = some m') : Reachable m'
  | flushLocal {m m' : Multi α cap} (h : Reachable m) (i : Nat)
      (hs : m.flushLocal i = some m') : Reachable m'
  | pushShared {m : Multi α cap} (h : Reachable m) (x : α) : Reachable (m.pushShared x)
  | takeLocal {m m' : Multi α cap} (h : Reachable m) (i : Nat)
      (hs : m.takeLocal i = some m') : Reachable m'
  | takeShared {m m' : Multi α cap} (h : Reachable m) (hs : m.takeShared = some m') :
      Reachable m'
  | stealInto {m m' : Multi α cap} (h : Reachable m) (i j : Nat)
      (hs : m.stealInto i j = some m') : Reachable m'
  | park {m m' : Multi α cap} (h : Reachable m) (i : Nat) (hs : m.park i = some m') :
      Reachable m'
  | tick {m : Multi α cap} (h : Reachable m) (i : Nat) : Reachable (m.tick i)
  | stop {m : Multi α cap} (h : Reachable m) : Reachable m.stop

theorem initial_wf {n : Nat} (hn : 0 < n) : (Multi.initial α cap n).WF := by
  refine ⟨?_, ?_, ?_⟩
  · simpa only [Multi.initial, List.length_replicate] using hn
  · simp only [Multi.initial, List.length_replicate]
  · intro p hp
    have hmem : p ∈ List.replicate n ({ emptyPool α with cap := cap }) := by
      simpa only [Multi.initial] using hp
    rw [(List.mem_replicate.mp hmem).2]

theorem initial_zeroParked : (Multi.initial α cap n).ZeroParked := by
  intro i p _ hq
  exfalso
  have h := replicate_false_get n i
  simp only [Multi.initial, Multi.parkedAt] at hq
  rw [h] at hq
  exact absurd hq (by simp)

theorem initial_injectWatched : (Multi.initial α cap n).InjectWatched := by
  intro h
  exact absurd rfl h

theorem initial_bounded : (Multi.initial α cap n).Bounded := by
  intro p hp
  have hmem : p ∈ List.replicate n ({ emptyPool α with cap := cap }) := by
    simpa only [Multi.initial] using hp
  rw [(List.mem_replicate.mp hmem).2]
  simp only [emptyPool]
  decide

theorem initial_consistent : (Multi.initial α cap n).Consistent := by
  have hheld : (Multi.initial α cap n).held = 0 := by
    have hp : Pool.inFlight ({ emptyPool α with cap := cap } : Pool α) = 0 := by
      simp [Pool.inFlight, Pool.contents, emptyPool]
    simp only [Multi.held, Multi.initial, List.map_replicate, hp, List.length_nil, Nat.add_zero]
    exact sum_replicate_zero n
  unfold Multi.Consistent
  rw [hheld]
  rfl

/-- What the obligations need of a reachable state: the carrier lists stay aligned, a parked carrier's
own pool is empty, a non-empty shared list has a running carrier, the allowances stay bounded, and the
conservation law holds. `Live` is derived from the first three below rather than carried here. -/
structure Multi.Invariant (m : Multi α cap) : Prop where
  wf : m.WF
  zeroParked : m.ZeroParked
  injectWatched : m.InjectWatched
  bounded : m.Bounded
  consistent : m.Consistent

theorem pushLocal_invariant {m m' : Multi α cap} {i : Nat} {x : α}
    (hs : m.pushLocal i x = some m') (h : m.Invariant) : m'.Invariant := by
  obtain ⟨p, hp, hnp, heq⟩ := pushLocal_spec hs
  rw [heq]
  have hcap : (p.submit m.inject.items x).2.cap = cap := by
    rw [submit_cap p m.inject.items x]
    exact h.wf.2.2 p (mem_of_getElem? hp)
  refine ⟨wf_setWorker h.wf hcap, zeroParked_setWorker h.zeroParked hp (Or.inl hnp), ?_, ?_, ?_⟩
  · intro _
    exact ⟨i, by simpa only [setAt_length] using length_of_getElem? hp, hnp⟩
  · refine bounded_setWorker h.bounded ?_
    have h1 := submit_lifoPolls p m.inject.items x
    have h2 := submit_lifoCap p m.inject.items x
    have h3 := h.bounded p (mem_of_getElem? hp)
    omega
  · have hh := held_pushLocal hs
    have hc := h.consistent
    rw [heq] at hh
    simp only [Multi.Consistent] at hc
    simp only [Multi.Consistent, Multi.held] at hh hc ⊢
    omega

theorem spawnLocal_invariant {m m' : Multi α cap} {i : Nat} {x : α}
    (hs : m.spawnLocal i x = some m') (h : m.Invariant) : m'.Invariant := by
  obtain ⟨p, hp, hnp, heq⟩ := spawnLocal_spec hs
  rw [heq]
  have hcap : (p.spawn m.inject.items x).2.cap = cap := by
    rw [spawn_cap p m.inject.items x]
    exact h.wf.2.2 p (mem_of_getElem? hp)
  refine ⟨wf_setWorker h.wf hcap, zeroParked_setWorker h.zeroParked hp (Or.inl hnp), ?_, ?_, ?_⟩
  · intro _
    exact ⟨i, by simpa only [setAt_length] using length_of_getElem? hp, hnp⟩
  · refine bounded_setWorker h.bounded ?_
    have h1 := spawn_lifoPolls p m.inject.items x
    have h2 := spawn_lifoCap p m.inject.items x
    have h3 := h.bounded p (mem_of_getElem? hp)
    omega
  · have hh := held_spawnLocal hs
    have hc := h.consistent
    rw [heq] at hh
    simp only [Multi.Consistent] at hc
    simp only [Multi.Consistent, Multi.held] at hh hc ⊢
    omega

theorem flushLocal_invariant {m m' : Multi α cap} {i : Nat}
    (hs : m.flushLocal i = some m') (h : m.Invariant) : m'.Invariant := by
  obtain ⟨p, hp, hnp, hsome, heq⟩ := flushLocal_spec hs
  rw [heq]
  have hcap : (p.flushSlot).2.cap = cap := by
    rw [flushSlot_cap p]
    exact h.wf.2.2 p (mem_of_getElem? hp)
  refine ⟨wf_setWorker h.wf hcap, zeroParked_setWorker h.zeroParked hp (Or.inl hnp), ?_, ?_, ?_⟩
  · intro _
    exact ⟨i, by simpa only [setAt_length] using length_of_getElem? hp, hnp⟩
  · refine bounded_setWorker h.bounded ?_
    have h1 := flushSlot_lifoPolls p
    have h2 := flushSlot_lifoCap p
    have h3 := h.bounded p (mem_of_getElem? hp)
    omega
  · have hh := held_flushLocal hs
    have hc := h.consistent
    rw [heq] at hh
    simp only [Multi.Consistent] at hc
    simp only [Multi.Consistent, Multi.held] at hh hc ⊢
    omega

theorem pushShared_invariant {m : Multi α cap} (h : m.Invariant) (x : α) :
    (m.pushShared x).Invariant := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · refine ⟨by simpa only [Multi.pushShared] using h.wf.1, ?_, ?_⟩
    · simpa only [Multi.pushShared, unparkOne_length] using h.wf.2.1
    · intro p hp
      exact h.wf.2.2 p (by simpa only [Multi.pushShared] using hp)
  · intro j r hj hq
    have hq' : m.parkedAt j = true := by
      have h1 : (unparkOne m.parked)[j]? = some true :=
        option_eq_some_true_of_getD (by simpa only [Multi.pushShared, Multi.parkedAt] using hq)
      have h2 := unparkOne_getElem?_true h1
      simp only [Multi.parkedAt, h2, Option.getD_some]
    exact h.zeroParked j r (by simpa only [Multi.pushShared] using hj) hq'
  · intro _
    exact ⟨0, h.wf.1, by simp only [Multi.pushShared, Multi.parkedAt]; exact unparkOne_getElem?_zero m.parked⟩
  · intro p hp
    exact h.bounded p (by simpa only [Multi.pushShared] using hp)
  · have hh := held_pushShared m x
    have hc := h.consistent
    simp only [Multi.Consistent] at hc
    simp only [Multi.Consistent, Multi.held, Multi.pushShared, Inject.push] at hh hc ⊢
    omega

theorem takeLocal_invariant {m m' : Multi α cap} {i : Nat}
    (hs : m.takeLocal i = some m') (h : m.Invariant) : m'.Invariant := by
  obtain ⟨p, hp, ht, heq⟩ := takeLocal_spec hs
  rw [heq]
  have hcap : (p.take).2.cap = cap := by
    rw [take_cap p]
    exact h.wf.2.2 p (mem_of_getElem? hp)
  refine ⟨wf_setWorker h.wf hcap, ?_, injectWatched_setWorker h.injectWatched, ?_, ?_⟩
  · refine zeroParked_setWorker h.zeroParked hp ?_
    by_cases hf : m.parkedAt i = false
    · exact Or.inl hf
    · refine Or.inr ?_
      have htrue : m.parkedAt i = true := by cases hb : m.parkedAt i <;> simp_all
      have hpz := h.zeroParked i p hp htrue
      have hpool := take_inFlight (p := p) ht
      omega
  · exact bounded_setWorker h.bounded (take_lifoPolls_le p (h.bounded p (mem_of_getElem? hp)))
  · have hh := held_takeLocal hs
    have hc := h.consistent
    rw [heq] at hh
    simp only [Multi.Consistent] at hc
    simp only [Multi.Consistent, Multi.held] at hh hc ⊢
    omega

theorem takeShared_invariant {m m' : Multi α cap} (hs : m.takeShared = some m')
    (h : m.Invariant) : m'.Invariant := by
  obtain ⟨hsome, heq⟩ := takeShared_spec hs
  rw [heq]
  refine ⟨h.wf, h.zeroParked, ?_, h.bounded, ?_⟩
  · intro hinj
    obtain ⟨j, hj, hf⟩ := h.injectWatched (by
      intro hnil
      apply hinj
      show (m.inject.pop).2.items = []
      have hlen := pop_length m.inject
      rw [hnil] at hlen
      simp only [List.length_nil] at hlen
      exact List.eq_nil_of_length_eq_zero (by omega))
    exact ⟨j, hj, hf⟩
  · have hh := held_takeShared hs
    have hc := h.consistent
    rw [heq] at hh
    simp only [Multi.Consistent] at hc
    simp only [Multi.Consistent, Multi.held] at hh hc ⊢
    omega

theorem stealInto_invariant {m m' : Multi α cap} {i j : Nat}
    (hs : m.stealInto i j = some m') (h : m.Invariant) : m'.Invariant := by
  obtain ⟨pv, hij, hpv, hsome, heq⟩ := stealInto_spec hs
  rw [heq]
  have hcap : (pv.takeFromRing).2.cap = cap := by
    rw [takeFromRing_cap pv]
    exact h.wf.2.2 pv (mem_of_getElem? hpv)
  refine ⟨wf_setWorker h.wf hcap, ?_, injectWatched_setWorker h.injectWatched, ?_, ?_⟩
  · refine zeroParked_setWorker h.zeroParked hpv ?_
    by_cases hf : m.parkedAt j = false
    · exact Or.inl hf
    · refine Or.inr ?_
      have htrue : m.parkedAt j = true := by cases hb : m.parkedAt j <;> simp_all
      have hpz := h.zeroParked j pv hpv htrue
      have hpool := takeFromRing_inFlight (p := pv) hsome
      omega
  · refine bounded_setWorker h.bounded ?_
    have h1 := takeFromRing_lifoPolls pv
    have h2 := takeFromRing_lifoCap pv
    have h3 := h.bounded pv (mem_of_getElem? hpv)
    omega
  · have hh := held_stealInto hs
    have hc := h.consistent
    rw [heq] at hh
    simp only [Multi.Consistent] at hc
    simp only [Multi.Consistent, Multi.held] at hh hc ⊢
    omega

theorem park_invariant {m m' : Multi α cap} {i : Nat}
    (hs : m.park i = some m') (h : m.Invariant) : m'.Invariant := by
  obtain ⟨p, hp, hempty, hinj, hfree, heq⟩ := park_spec hs
  rw [heq]
  refine ⟨?_, ?_, ?_, h.bounded, ?_⟩
  · refine ⟨h.wf.1, ?_, h.wf.2.2⟩
    rw [setAt_length]
    exact h.wf.2.1
  · intro j r hj hq
    by_cases hji : j = i
    · subst j
      have hr : r = p := Option.some.inj (hj.symm.trans hp)
      rw [hr]
      exact hempty
    · have hq' : m.parkedAt j = true := by
        have h1 := hq
        simp only [Multi.parkedAt] at h1 ⊢
        rwa [getElem?_setAt_ne (l := m.parked) (i := i) (j := j) (b := true)
          (fun hh => hji hh.symm)] at h1
      exact h.zeroParked j r hj hq'
  · intro hne
    rw [hinj] at hne
    exact absurd rfl hne
  · have hh := held_park hs
    have hc := h.consistent
    rw [heq] at hh
    simp only [Multi.Consistent] at hc
    simp only [Multi.Consistent, Multi.held] at hh hc ⊢
    omega

theorem tick_invariant {m : Multi α cap} (h : m.Invariant) (i : Nat) :
    (m.tick i).Invariant := by
  unfold Multi.tick
  split
  · exact h
  · rename_i p hw
    have hcap : p.tick.cap = cap := by
      rw [tick_cap p]
      exact h.wf.2.2 p (mem_of_getElem? hw)
    refine ⟨wf_setWorker h.wf hcap, zeroParked_setWorker h.zeroParked hw ?_,
      injectWatched_setWorker h.injectWatched, ?_, ?_⟩
    · by_cases hf : m.parkedAt i = false
      · exact Or.inl hf
      · refine Or.inr ?_
        have htrue : m.parkedAt i = true := by cases hb : m.parkedAt i <;> simp_all
        have hpz := h.zeroParked i p hw htrue
        rw [tick_inFlight]
        exact hpz
    · refine bounded_setWorker h.bounded ?_
      rw [tick_lifoPolls, tick_lifoCap]
      exact Nat.zero_le _
    · have hh := held_tick_at hw
      have hc := h.consistent
      simp only [Multi.Consistent] at hc
      simp only [Multi.Consistent, Multi.held] at hh hc ⊢
      omega

theorem stop_invariant {m : Multi α cap} (h : m.Invariant) : m.stop.Invariant :=
  ⟨h.wf, h.zeroParked, h.injectWatched, h.bounded, h.consistent⟩

theorem Multi.reachable_invariant {m : Multi α cap} (h : m.Reachable) : m.Invariant := by
  induction h with
  | init n hn =>
    exact ⟨initial_wf hn, initial_zeroParked, initial_injectWatched, initial_bounded,
      initial_consistent⟩
  | pushLocal _ _ _ hs ih => exact pushLocal_invariant hs ih
  | spawnLocal _ _ _ hs ih => exact spawnLocal_invariant hs ih
  | flushLocal _ _ hs ih => exact flushLocal_invariant hs ih
  | pushShared _ x ih => exact pushShared_invariant ih x
  | takeLocal _ _ hs ih => exact takeLocal_invariant hs ih
  | takeShared _ hs ih => exact takeShared_invariant hs ih
  | stealInto _ _ _ hs ih => exact stealInto_invariant hs ih
  | park _ _ hs ih => exact park_invariant hs ih
  | tick _ i ih => exact tick_invariant ih i
  | stop _ ih => exact stop_invariant ih

/-! ### The obligations -/

/-- Every reachable state is well-formed: one flag per carrier, at least one carrier, every carrier's
capacity the type parameter's. -/
theorem Multi.reachable_wf {m : Multi α cap} (h : m.Reachable) : m.WF :=
  (Multi.reachable_invariant h).wf

/-- Every reachable state has no parked carrier holding work of its own. -/
theorem Multi.reachable_zeroParked {m : Multi α cap} (h : m.Reachable) : m.ZeroParked :=
  (Multi.reachable_invariant h).zeroParked

/-- Every reachable state with a non-empty shared list has a carrier that is not parked. -/
theorem Multi.reachable_injectWatched {m : Multi α cap} (h : m.Reachable) : m.InjectWatched :=
  (Multi.reachable_invariant h).injectWatched

/-- A reachable state where every carrier is parked holds nothing: `ZeroParked` empties the carriers'
own queues and `InjectWatched` empties the shared list. This is the step `Live` is derived through. -/
theorem Multi.held_eq_zero_of_allParked {m : Multi α cap} (h : m.Invariant)
    (hall : m.parkedCount = m.workers.length) : m.held = 0 := by
  have hlen : m.parked.length = m.workers.length := h.wf.2.1
  have halltrue : ∀ b ∈ m.parked, b = true :=
    all_true_of_filter_id_length_eq (by rw [Multi.parkedCount] at hall; omega)
  have hsum : (m.workers.map Pool.inFlight).sum = 0 := by
    refine sum_eq_zero_of_forall_getElem m.workers Pool.inFlight ?_
    intro i hi
    have hi' : i < m.parked.length := by rw [hlen]; exact hi
    have hb := List.getElem?_eq_getElem hi'
    have hbt : m.parked[i] = true := halltrue m.parked[i] (List.getElem_mem hi')
    have hpark : m.parkedAt i = true := by
      simp only [Multi.parkedAt, hb, Option.getD_some]
      exact hbt
    exact h.zeroParked i m.workers[i] (List.getElem?_eq_getElem hi) hpark
  have hinj : m.inject.items = [] := by
    cases hi : m.inject.items with
    | nil => rfl
    | cons y rest =>
      obtain ⟨j, hj, hf⟩ := h.injectWatched (by simp [hi])
      have hlt : j < m.parked.length := by rw [hlen]; exact hj
      have hb := List.getElem?_eq_getElem hlt
      have hbt : m.parked[j] = true := halltrue m.parked[j] (List.getElem_mem hlt)
      have hpark : m.parkedAt j = true := by
        simp only [Multi.parkedAt, hb, Option.getD_some]
        exact hbt
      rw [hpark] at hf
      exact absurd hf (by simp)
  simp only [Multi.held, hsum, hinj, List.length_nil, Nat.add_zero]

/-- **No lost wakeup.** Every reachable state either holds nothing or has a carrier that is not
parked. -/
theorem Multi.reachable_live {m : Multi α cap} (h : m.Reachable) : m.Live := by
  have hinv := Multi.reachable_invariant h
  by_cases h0 : m.held = 0
  · exact Or.inl h0
  · refine Or.inr ?_
    by_cases hcount : m.parkedCount < m.workers.length
    · exact hcount
    · exfalso
      have heq : m.parkedCount = m.workers.length := by
        show (m.parked.filter id).length = m.workers.length
        have h1 := filter_id_length_le m.parked
        rw [hinv.wf.2.1] at h1
        exact Nat.le_antisymm h1 (Nat.le_of_not_lt hcount)
      exact h0 (Multi.held_eq_zero_of_allParked hinv heq)

/-- **No lost work.** Every reachable state conserves work over the composition: everything submitted is
held or was taken, the steal included, since a thief's item leaves the victim's ring and is counted as
taken. -/
theorem Multi.reachable_consistent {m : Multi α cap} (h : m.Reachable) : m.Consistent :=
  (Multi.reachable_invariant h).consistent

/-- **Bounded work per tick.** Every reachable state keeps each carrier's allowance within its own
limit. -/
theorem Multi.reachable_bound {m : Multi α cap} (h : m.Reachable) : m.Bounded :=
  (Multi.reachable_invariant h).bounded

/-- **The single-carrier obligation is a corollary of the multi-carrier one**, through the projection:
the abstract state's `Live` is the composition's `Live` read at its counts. -/
theorem Multi.reachable_toSched_live {m : Multi α cap} (h : m.Reachable) : m.toSched.Live :=
  Multi.reachable_live h

/-- **The allowance is per carrier.** A tick at carrier `i` leaves every other carrier's queue — its
allowance included — exactly as it was. -/
theorem Multi.tick_other_untouched (m : Multi α cap) {i j : Nat} (h : i ≠ j) :
    (m.tick i).workers[j]? = m.workers[j]? := by
  unfold Multi.tick
  split
  · rfl
  · rename_i p _
    exact getElem?_setAt_ne (l := m.workers) (i := i) (j := j) (b := p.tick) h

/-- A take the pool's own queue serves is a take the carrier's step performs. -/
theorem takeLocal_isSome_of {m : Multi α cap} {i : Nat} {p : Pool α}
    (hp : m.workers[i]? = some p) (h : (p.take).1.isSome) : (m.takeLocal i).isSome := by
  unfold Multi.takeLocal
  rw [hp]
  dsimp only
  rw [ite_eq_left h]
  rfl

/-- A slot cleared for the shared list is a flush the step performs, for a carrier that is not parked. -/
theorem flushLocal_isSome_of {m : Multi α cap} {i : Nat} {p : Pool α}
    (hp : m.workers[i]? = some p) (hnp : m.parkedAt i = false)
    (h : (p.flushSlot).1.isSome) : (m.flushLocal i).isSome := by
  unfold Multi.flushLocal
  rw [hp]
  dsimp only
  rw [ite_eq_left hnp, ite_eq_left h]
  rfl

/-- A non-empty shared list is the step's third arm. -/
theorem takeShared_isSome_of {m : Multi α cap} (h : m.inject.items ≠ []) : m.takeShared.isSome := by
  have h' : (m.inject.pop).1.isSome = true := pop_returns_if_present m.inject h
  unfold Multi.takeShared
  rw [ite_eq_left h']
  rfl

/-- **No stranded work at a carrier's step.** The step a carrier takes over its own queue and the shared
list — clear a spent slot for the shared list, then serve the ring, then the shared list — serves
something whenever the carrier's own view holds anything. This is the multi-carrier form of the pool's
`take_returns_if_present`: the pool cannot promise it alone, because the spent slot's destination is
shared. -/
theorem Multi.takeStep_returns_if_present {m : Multi α cap} {i : Nat} {p : Pool α}
    (hp : m.workers[i]? = some p) (hnp : m.parkedAt i = false)
    (h : p.inFlight + m.inject.items.length ≠ 0) :
    (m.flushLocal i).isSome ∨ (m.takeLocal i).isSome ∨ m.takeShared.isSome := by
  by_cases hinj : m.inject.items = []
  · have hpw : p.inFlight ≠ 0 := by
      rw [hinj, List.length_nil, Nat.add_zero] at h
      exact h
    by_cases hring : p.ring ≠ []
    · exact Or.inr (Or.inl (takeLocal_isSome_of hp (take_returns_if_present hring)))
    · have hring' : p.ring = [] := by
        cases hr : p.ring with
        | nil => rfl
        | cons y rest => exact absurd (by rw [hr]; simp) hring
      have hslot : p.lifo.isSome := by
        cases hl : p.lifo with
        | none =>
          have hzero : Pool.inFlight p = 0 := by
            simp [Pool.inFlight, Pool.contents, hring', hl]
          exact absurd hzero hpw
        | some y => rfl
      by_cases hpoll : p.lifoPolls < p.lifoCap
      · exact Or.inr (Or.inl (takeLocal_isSome_of hp (take_returns_if_slot_present hpoll hslot)))
      · exact Or.inl (flushLocal_isSome_of hp hnp (flushSlot_returns_if_present hslot))
  · exact Or.inr (Or.inr (takeShared_isSome_of hinj))

/-! ### The controls

Each obligation's hypothesis must be load-bearing, in the shape `Model/Scheduler.lean`'s
`enqueueWithoutWaking_breaks_live` uses: a reachable state, and the step with the load-bearing half
removed destroying the invariant. Each violation is staged through real transitions rather than written
down. -/

/-- **A push into the shared list without the wake** — the append with the un-parking removed. -/
def Multi.pushSharedWithoutWaking (m : Multi α cap) (x : α) : Multi α cap :=
  { m with inject := m.inject.push x, pushed := m.pushed + 1 }

/-- **A park that does not test the carrier's own queue** — the emptiness test dropped. -/
def Multi.parkHoldingOwnWork (m : Multi α cap) (i : Nat) : Option (Multi α cap) :=
  match m.workers[i]? with
  | none => none
  | some _ =>
    if m.parkedAt i = false then
      some { m with parked := setAt m.parked i true }
    else none

/-- **A steal that drops the item** — the ring's element removed with the take left uncounted. -/
def Multi.stealDropping (m : Multi α cap) (i j : Nat) : Option (Multi α cap) :=
  if i = j then none
  else
    match m.workers[j]? with
    | none => none
    | some pv =>
      match m.workers[i]? with
      | none => none
      | some _ =>
        if (pv.takeFromRing).1.isSome then
          some { m with workers := setAt m.workers j (pv.takeFromRing).2 }
        else none

/-- One carrier, parked: the fresh state after `park`, staged by the transition itself. -/
def oneParked (α : Type) (cap : Nat) : Multi α cap :=
  { Multi.initial α cap 1 with parked := [true] }

theorem oneParked_reachable (α : Type) (cap : Nat) : (oneParked α cap).Reachable :=
  Multi.Reachable.park (Multi.Reachable.init 1 (by omega)) 0 rfl

/-- One carrier whose ring holds `x`: the fresh state after a local push, staged by the transition
itself. Needs room in the ring, which is what `0 < cap` says. -/
def oneRing (α : Type) (cap : Nat) (x : α) : Multi α cap :=
  let p := ({ emptyPool α with cap := cap } : Pool α)
  { workers := [(p.submit [] x).2]
    inject := { items := (p.submit [] x).1 }
    parked := [false]
    pushed := 1 }

theorem oneRing_reachable (α : Type) (cap : Nat) (x : α) : (oneRing α cap x).Reachable :=
  Multi.Reachable.pushLocal (Multi.Reachable.init 1 (by omega)) 0 x rfl

/-- That carrier parked with the emptiness test dropped: what `parkHoldingOwnWork` produces. -/
def oneRingParkedBroken (α : Type) (cap : Nat) (x : α) : Multi α cap :=
  { oneRing α cap x with parked := [true] }

/-- Two carriers, the second one's ring holding `x`: the fresh state after a local push at that
carrier. Needs room in the ring, which is what `0 < cap` says. -/
def twoRing (α : Type) (cap : Nat) (x : α) : Multi α cap :=
  let p := ({ emptyPool α with cap := cap } : Pool α)
  { workers := [p, (p.submit [] x).2]
    inject := { items := (p.submit [] x).1 }
    parked := [false, false]
    pushed := 1 }

theorem twoRing_reachable (α : Type) (cap : Nat) (x : α) : (twoRing α cap x).Reachable :=
  Multi.Reachable.pushLocal (Multi.Reachable.init 2 (by omega)) 1 x rfl

/-- The same state with the victim's ring element gone and the take left uncounted: what
`stealDropping` produces. -/
def twoRingStolen (α : Type) (cap : Nat) (x : α) : Multi α cap :=
  let p := ({ emptyPool α with cap := cap } : Pool α)
  { workers := [p, (p.submit [] x).2.takeFromRing.2]
    inject := { items := (p.submit [] x).1 }
    parked := [false, false]
    pushed := 1 }

theorem held_oneParked : (oneParked α cap).held = 0 := by
  simp [Multi.held, oneParked, Multi.initial, Pool.inFlight, Pool.contents, emptyPool]

theorem held_oneParked_pushShared (x : α) :
    ((oneParked α cap).pushSharedWithoutWaking x).held = 1 := by
  simp [Multi.held, Multi.pushSharedWithoutWaking, oneParked, Multi.initial, Inject.push,
    Pool.inFlight, Pool.contents, emptyPool]

theorem count_oneParked_pushShared (x : α) :
    ((oneParked α cap).pushSharedWithoutWaking x).parkedCount = 1 ∧
      ((oneParked α cap).pushSharedWithoutWaking x).workers.length = 1 := by
  refine ⟨?_, ?_⟩ <;> simp [Multi.parkedCount, Multi.pushSharedWithoutWaking, oneParked, Multi.initial]

theorem inFlight_oneRing (x : α) (hcap : 0 < cap) :
    (({ emptyPool α with cap := cap } : Pool α).submit [] x).2.inFlight = 1 := by
  simp [Pool.inFlight, Pool.contents, Pool.submit, Pool.toRing, hcap, emptyPool]

theorem held_twoRingStolen (x : α) (hcap : 0 < cap) : (twoRingStolen α cap x).held = 0 := by
  simp [Multi.held, twoRingStolen, Pool.inFlight, Pool.contents, Pool.submit, Pool.toRing,
    Pool.takeFromRing, hcap, emptyPool]

/-- **The shared half is load-bearing.** From a reachable state with every carrier parked and an empty
shared list, the same push with the wake removed holds work with every carrier still parked — the lost
wakeup `Multi.Live` proves against. -/
theorem pushSharedWithoutWaking_breaks_live (x : α) :
    ∃ m : Multi α cap, m.Reachable ∧ m.Live ∧ ¬ (m.pushSharedWithoutWaking x).Live := by
  refine ⟨oneParked α cap, oneParked_reachable α cap, Or.inl held_oneParked, ?_⟩
  intro hc
  rcases hc with h0 | hlt
  · have h1 := held_oneParked_pushShared (α := α) (cap := cap) x
    omega
  · obtain ⟨hc', hl'⟩ := count_oneParked_pushShared (α := α) (cap := cap) x
    omega

/-- **The local half is load-bearing.** A park that does not test its own queue leaves a parked carrier
holding work of its own, which is exactly what `ZeroParked` forbids — and the state it is staged from is
reachable, the work having arrived by a real local push. `0 < cap` is what puts the task in the ring. -/
theorem parkHoldingOwnWork_breaks_ZeroParked (x : α) (hcap : 0 < cap) :
    ∃ m m' : Multi α cap,
      m.Reachable ∧ m.parkHoldingOwnWork 0 = some m' ∧ ¬ m'.ZeroParked := by
  refine ⟨oneRing α cap x, oneRingParkedBroken α cap x, oneRing_reachable α cap x, rfl, ?_⟩
  intro hz
  have h0 := hz 0 (({ emptyPool α with cap := cap } : Pool α).submit [] x).2 rfl rfl
  have hq := inFlight_oneRing (α := α) (cap := cap) x hcap
  omega

/-- **The steal counts what it removes.** From a reachable state holding one item in a victim's ring, a
steal that removes the element without counting the take leaves less held and taken than submitted. -/
theorem stealDropping_breaks_consistent (x : α) (hcap : 0 < cap) :
    ∃ m m' : Multi α cap,
      m.Reachable ∧ m.stealDropping 0 1 = some m' ∧ ¬ m'.Consistent := by
  refine ⟨twoRing α cap x, twoRingStolen α cap x, twoRing_reachable α cap x, ?_, ?_⟩
  · have hsome : ((({ emptyPool α with cap := cap } : Pool α).submit [] x).2.takeFromRing).1.isSome
        = true := by
      simp [Pool.takeFromRing, Pool.submit, Pool.toRing, hcap, emptyPool]
    simp only [Multi.stealDropping, twoRing, twoRingStolen]
    rw [ite_eq_right (by decide : ¬((0 : Nat) = 1))]
    simp only [List.getElem?_cons_zero, List.getElem?_cons_succ]
    rw [ite_eq_left hsome]
    rfl
  · intro hc
    unfold Multi.Consistent at hc
    have h0 := held_twoRingStolen (α := α) (cap := cap) x hcap
    have hp : (twoRingStolen α cap x).pushed = 1 := rfl
    have ht : (twoRingStolen α cap x).taken = 0 := rfl
    omega

/-- **A poll past the allowance** — the slot polled again instead of being cleared for the shared list,
with the limit ignored: the fourth poll the allowance's flush exists to prevent. -/
def Multi.pollPastAllowance (m : Multi α cap) (i : Nat) : Option (Multi α cap) :=
  match m.workers[i]? with
  | none => none
  | some p =>
    match p.lifo with
    | none => none
    | some _ => some { m with workers := setAt m.workers i { p with lifoPolls := p.lifoPolls + 1 } }

/-- A staged single-carrier state: `polls` polls used, the slot holding `x` when `held`, and the counts
that go with the round that produced it. The carrier's own count and the composition's are the same
number at every stage, which is what lets the staged equations below hold by reduction. -/
def stagedState (α : Type) (cap : Nat) (x : α) (polls : Nat) (held : Bool) : Multi α cap :=
  { workers := [{ ({ emptyPool α with cap := cap } : Pool α) with
                  lifo := if held then some x else none
                  lifoPolls := polls
                  pushed := polls + (if held then 1 else 0)
                  taken := polls }]
    inject := { items := [] }
    parked := [false]
    pushed := polls + (if held then 1 else 0)
    taken := polls }

/-- The staged state with one more poll counted than the allowance allows: what `pollPastAllowance`
produces on a spent allowance. -/
def stagedPolled (α : Type) (cap : Nat) (x : α) : Multi α cap :=
  { stagedState α cap x 3 true with
    workers := [{ ({ emptyPool α with cap := cap } : Pool α) with
                  lifo := some x
                  lifoPolls := 4
                  pushed := 4
                  taken := 3 }] }

theorem stagedState_reachable (α : Type) (cap : Nat) (x : α) :
    (stagedState α cap x 3 true).Reachable :=
  Multi.Reachable.spawnLocal (m' := stagedState α cap x 3 true)
    (Multi.Reachable.takeLocal (m' := stagedState α cap x 3 false)
      (Multi.Reachable.spawnLocal (m' := stagedState α cap x 2 true)
        (Multi.Reachable.takeLocal (m' := stagedState α cap x 2 false)
          (Multi.Reachable.spawnLocal (m' := stagedState α cap x 1 true)
            (Multi.Reachable.takeLocal (m' := stagedState α cap x 1 false)
              (Multi.Reachable.spawnLocal (m' := stagedState α cap x 0 true)
                (Multi.Reachable.init 1 (by omega)) 0 x rfl)
              0 rfl)
            0 x rfl)
          0 rfl)
        0 x rfl)
      0 rfl)
    0 x rfl

/-- **The allowance is load-bearing.** A spent allowance with the slot still occupied is a slot the step
must clear; polling it a fourth time instead — the near miss the allowance's flush exists to prevent —
carries the carrier's poll count past its limit, from a reachable state. -/
theorem fourthPoll_breaks_bound (x : α) :
    ∃ m m' : Multi α cap,
      m.Reachable ∧ m.pollPastAllowance 0 = some m' ∧ ¬ m'.Bounded := by
  refine ⟨stagedState α cap x 3 true, stagedPolled α cap x, stagedState_reachable α cap x, rfl, ?_⟩
  intro h
  have h4 := h _ (List.Mem.head [])
  simp only [emptyPool] at h4
  omega

/-! ### Vacuity checks

Each predicate must be shown to distinguish, or a theorem about it is true of everything and means
nothing. The composition is written through `Multi.initial`, so the examples reduce, in the idiom
`Model/Pool.lean`'s vacuity checks use: one positive and one distinguishing negative per predicate. -/

/-- A fresh composition is consistent: nothing submitted, nothing taken. -/
example : (Multi.initial Nat 256 2).Consistent := by
  unfold Multi.Consistent
  decide

/-- …and an inconsistent one exists, so `Consistent` is not true of everything. -/
example : ¬ ({(Multi.initial Nat 256 2) with pushed := 1} : Multi Nat 256).Consistent := by
  unfold Multi.Consistent
  decide

/-- A fresh composition is live… -/
example : (Multi.initial Nat 256 2).Live := by
  unfold Multi.Live
  decide

/-- …and its negation is inhabited: work held with every carrier parked, which is exactly the state
`reachable_live` says the protocol cannot produce. -/
example :
    ¬ ({(Multi.initial Nat 256 1) with inject := { items := [0] }, parked := [true]} :
        Multi Nat 256).Live := by
  unfold Multi.Live Multi.held
  decide

/-- A fresh composition is well-formed: one flag per carrier, every carrier's capacity the
parameter's. -/
example : (Multi.initial Nat 256 2).WF := initial_wf (by omega)

/-- …and one with a flag too many exists, so `WF` is not true of everything. -/
example : ¬ ({(Multi.initial Nat 256 2) with parked := [true]} : Multi Nat 256).WF := by
  intro h
  have h1 := h.2.1
  simp only [Multi.initial, List.length_replicate, List.length_cons, List.length_nil] at h1
  omega

/-- A fresh composition has no parked carrier holding its own work. -/
example : (Multi.initial Nat 256 2).ZeroParked := initial_zeroParked

/-- …and one exists where a parked carrier does, which is what `ZeroParked` forbids. -/
example : ¬ (oneRingParkedBroken Nat 256 0).ZeroParked := by
  intro h
  have h0 := h 0 ((({ emptyPool Nat with cap := 256 } : Pool Nat)).submit [] 0).2 rfl rfl
  simp [Pool.inFlight, Pool.contents, Pool.submit, Pool.toRing, emptyPool] at h0

/-- A fresh composition's shared list is empty, so `InjectWatched`'s hypothesis is not met. -/
example : (Multi.initial Nat 256 2).InjectWatched := initial_injectWatched

/-- …and one exists that it rejects: a non-empty shared list with every carrier parked. -/
example :
    ¬ ({(Multi.initial Nat 256 1) with inject := { items := [0] }, parked := [true]} :
        Multi Nat 256).InjectWatched := by
  intro h
  have hne : ({(Multi.initial Nat 256 1) with inject := { items := [0] }, parked := [true]} :
      Multi Nat 256).inject.items ≠ [] := by decide
  obtain ⟨i, hi, hf⟩ := h hne
  have hi0 : i = 0 := by simp only [Multi.initial, List.length_replicate] at hi; omega
  subst hi0
  simp [Multi.parkedAt] at hf

/-- A fresh composition's allowances are zero, within each carrier's limit. -/
example : (Multi.initial Nat 256 2).Bounded := initial_bounded

/-- …and one exists whose allowance exceeds its limit, so `Bounded` is not true of everything. -/
example : ¬ ({(Multi.initial Nat 256 1) with
    workers := [{ emptyPool Nat with lifoPolls := 4 }]} : Multi Nat 256).Bounded := by
  intro h
  have h4 : ({ emptyPool Nat with lifoPolls := 4 } : Pool Nat).lifoPolls
      ≤ ({ emptyPool Nat with lifoPolls := 4 } : Pool Nat).lifoCap :=
    h _ (List.Mem.head [])
  simp only [emptyPool] at h4
  omega

/-! ### The audit

The composition's obligations rest on nothing beyond Lean's own axioms, as the pool's and the protocol's
do: the inject is a list and the carriers are lists, so nothing here reaches a primitive. -/

#print axioms LeanIn.Model.Multi.reachable_live
#print axioms LeanIn.Model.Multi.reachable_consistent
#print axioms LeanIn.Model.Multi.reachable_bound
#print axioms LeanIn.Model.Multi.reachable_toSched_live
#print axioms LeanIn.Model.Multi.tick_other_untouched
#print axioms LeanIn.Model.Multi.takeStep_returns_if_present
#print axioms LeanIn.Model.pushSharedWithoutWaking_breaks_live
#print axioms LeanIn.Model.parkHoldingOwnWork_breaks_ZeroParked
#print axioms LeanIn.Model.stealDropping_breaks_consistent
#print axioms LeanIn.Model.fourthPoll_breaks_bound

end Model

end LeanIn

end
