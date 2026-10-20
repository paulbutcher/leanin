module

public import Std
public import LeanIn.Data.Slots


public section
-- `toList` and the build lemmas need `Inhabited`; the index arithmetic does not.
set_option linter.unusedSectionVars false

/-!
# The deque: an unbounded queue over the ring's store

The inject queue is a FIFO that is appended at the back and taken from the front, and the append is the burst
path. `LeanIn.Data.Ring` is the *bounded* container the pool's ring uses, and a ring cannot serve an unbounded
queue: a full ring has to evict, and there is nothing to evict to. So the inject needs the same store with no
capacity, and this is it — `LeanIn.Data.Slots`'s fields, the same index rules, a ghost view that indexes
absolutely rather than modulo a capacity, and no `Bounded`: the inject is unbounded by decision, and a bound on
a container the resume path writes is a bound the runtime could not honour.

**Shape.** `head` is an absolute index into `slots`, and the live range is `[head, head + size)`. `push` writes
at `head + size`; `pop` clears `head` and advances. When the tail is exhausted and `head > 0` the store is
**compacted** — the live range is copied to the front and `head` goes back to zero — so a deque that is drained
and refilled at a small size does not grow its array for ever. When the tail is exhausted and `head = 0` the
store **grows**: a larger array is allocated with the live range at the front, and the new element is written
into the room it leaves. Both copies are O(live), so the asymptotics are a growable queue's; the reason for
this container is structural reuse — the store and its index arithmetic are the ring's, shared rather than
re-derived, and nothing here depends on a library whose own header calls itself a placeholder.

`Deque.toList` is the ghost view and the whole specification of this container: a push appends to the view's
back, a pop removes from its front, and the *append lemma* below is what carries the implementation to the
model's `inject : List α`, in the D12 container-and-ghost-view pattern the ring established.
-/

namespace LeanIn

/-- An unbounded FIFO queue over `Slots`: push at the back, pop at the front. -/
structure Deque (α : Type) extends Slots α
deriving Inhabited, Repr

variable {α : Type} [Inhabited α]

/-- **The ghost view.** The live elements, oldest first, read through the store's index function: absolute, so
nothing below this line sees a modulus. -/
@[expose] def Deque.toList (d : Deque α) : List α :=
  d.toSlots.toList (fun i => d.head + i)

/-- Well-formedness: the live range is inside the store, and it is **dense** — every index the view reads
holds an element, not an empty slot. -/
@[expose] def Deque.WF (d : Deque α) : Prop :=
  d.head + d.size ≤ d.slots.size ∧
  ∀ i, i < d.size → ((d.slots[d.head + i]?).join).isSome

/-- The empty deque. -/
def Deque.empty : Deque α := {}

/-- A fresh deque is well-formed: no live range, so nothing to hold and nothing to read. -/
theorem Deque.empty_wf : (Deque.empty (α := α)).WF := by
  refine ⟨by simp [Deque.empty], ?_⟩
  intro i hi
  simp [Deque.empty] at hi

/-- **The view has as many elements as the deque reports.** -/
theorem Deque.toList_length (d : Deque α) : d.toList.length = d.size :=
  Slots.toList_length _ _

/-! ### Building a store from a list

Both the compaction and the growth paths rebuild the store from the view: a fresh array holding the live range
from index `0`, with `room` empty slots after it. These lemmas are the whole proof obligation a rebuild
carries — that the view reads the same elements back, and that what it reads is present. -/

/-- **The rebuilt store**: a fresh array holding `live` from index `0`, with `room` empty slots after it.
Both the compaction and the growth path build exactly this, and `toList_ofList`/`dense_ofList` below are the
whole proof obligation a rebuild carries — that the view reads the same elements back, and that what it
reads is present. -/
def Slots.ofList (live : List α) (room : Nat) : Slots α :=
  { slots := (live.map some ++ List.replicate room none).toArray
    head  := 0
    size  := live.length }

/-- The rebuilt store holds exactly `live.length + room` slots, so a write at `live.length` lands inside it
whenever `room > 0`. -/
theorem Slots.ofList_size (live : List α) (room : Nat) :
    (Slots.ofList live room).slots.size = live.length + room := by
  unfold Slots.ofList
  rw [List.size_toArray, List.length_append, List.length_map, List.length_replicate]

/-- The live slot at a live index holds an element: the store's density, read one index at a time. -/
theorem Slots.ofList_isSome (live : List α) (room i : Nat) (hi : i < live.length) :
    ((((live.map some ++ List.replicate room none).toArray)[i]?).join).isSome := by
  rw [List.getElem?_toArray]
  rw [List.getElem?_append_left (by simpa using hi : i < (live.map some).length)]
  rw [List.getElem?_map, List.getElem?_eq_getElem hi]
  rfl

/-- …and the view reads that element, not a default: the store's ghost view at a live index. -/
theorem Slots.ofList_getElem? (live : List α) (room i : Nat) (hi : i < live.length) :
    ((((live.map some ++ List.replicate room none).toArray)[i]?).join).getD default = live[i] := by
  rw [List.getElem?_toArray]
  rw [List.getElem?_append_left (by simpa using hi : i < (live.map some).length)]
  rw [List.getElem?_map, List.getElem?_eq_getElem hi]
  rfl

/-- **The rebuilt store's view is the list it was built from.** -/
theorem Slots.toList_ofList (live : List α) (room : Nat) :
    (Slots.ofList live room).toList (fun i => i) = live := by
  unfold Slots.ofList Slots.toList
  apply List.ext_getElem?
  intro i
  by_cases hi : i < live.length
  · rw [List.getElem?_map, List.getElem?_range hi]
    simp only [Option.map_some]
    rw [Slots.ofList_getElem? live room i hi, List.getElem?_eq_getElem hi]
  · rw [List.getElem?_eq_none (by simpa using Nat.le_of_not_lt hi),
        List.getElem?_eq_none (Nat.le_of_not_lt hi)]

/-- **The rebuilt store's live range is dense.** -/
theorem Slots.dense_ofList (live : List α) (room : Nat) :
    Slots.Dense (Slots.ofList live room) (fun i => i) := by
  intro i hi
  exact Slots.ofList_isSome live room i (by simpa [Slots.ofList] using hi)

/-! ### The operations -/

/-- Write one element at the free position and grow the live count. The caller has established that the
position is inside the store. -/
@[expose] def Deque.write (d : Deque α) (x : α) : Deque α :=
  { d with slots := d.slots.setIfInBounds (d.head + d.size) (some x), size := d.size + 1 }

/-- **Rebuild the store**: the live range copied to a fresh array with `room` empty slots after it, and the
head reset. This is the one move both the compaction and the growth cost, and `Slots.toList_ofList` is what
says it does not change what the deque holds. -/
@[expose] def Deque.rebuild (d : Deque α) (room : Nat) : Deque α :=
  { toSlots := Slots.ofList d.toList room }

/-- **Push at the back.** Write in place when the tail has room; compact the consumed prefix when it does not
and the head has advanced; grow the store when the head is already at zero. -/
@[expose] def Deque.push (d : Deque α) (x : α) : Deque α :=
  if d.head + d.size < d.slots.size then d.write x
  else if 0 < d.head then (d.rebuild (max 1 (d.slots.size - d.size))).write x
  else (d.rebuild (max 1 (2 * d.size))).write x

/-- **Pop from the front.** No element moves; the head advances. -/
@[expose] def Deque.pop (d : Deque α) : Option α × Deque α :=
  if 0 < d.size then
    match d.slots[d.head]? with
    | some (some x) =>
      (some x, { d with slots := d.slots.setIfInBounds d.head none,
                        head  := d.head + 1,
                        size  := d.size - 1 })
    | _ => (none, d)
  else (none, d)

/-! ### The laws tying the container to the spec -/

/-- A rebuild leaves room to write, so its free position is inside the store. -/
theorem Deque.rebuild_pos (d : Deque α) (room : Nat) (h : 0 < room) :
    (d.rebuild room).head + (d.rebuild room).size < (d.rebuild room).slots.size := by
  have hslots : (d.rebuild room).slots = (Slots.ofList d.toList room).slots := rfl
  have hsize : (d.rebuild room).size = d.toList.length := rfl
  have hhead : (d.rebuild room).head = 0 := rfl
  rw [hslots, hhead, hsize, Slots.ofList_size]
  omega

/-- A rebuild does not change the view. -/
theorem Deque.rebuild_toList (d : Deque α) (room : Nat) : (d.rebuild room).toList = d.toList := by
  have hhead : (d.rebuild room).head = 0 := rfl
  unfold Deque.toList
  rw [hhead]
  simp only [Nat.zero_add]
  exact Slots.toList_ofList d.toList room

/-- A rebuild's live range is dense. -/
theorem Deque.rebuild_dense (d : Deque α) (room : Nat) :
    ∀ i, i < (d.rebuild room).size →
      (((d.rebuild room).slots[(d.rebuild room).head + i]?).join).isSome := by
  have hslots : (d.rebuild room).slots = (Slots.ofList d.toList room).slots := rfl
  have hhead : (d.rebuild room).head = 0 := rfl
  intro i hi
  have hi' : i < d.toList.length := hi
  rw [hslots, hhead]
  simp only [Nat.zero_add]
  exact Slots.dense_ofList d.toList room i hi'

/-- The write's own view law: a write at a position inside the store appends to the view. -/
theorem Deque.write_toList (d : Deque α) (x : α) (hroom : d.head + d.size < d.slots.size) :
    (d.write x).toList = d.toList ++ [x] := by
  have hsl : (d.write x).slots = d.slots.setIfInBounds (d.head + d.size) (some x) := rfl
  have hhd : (d.write x).head = d.head := rfl
  have hsz : (d.write x).size = d.size + 1 := rfl
  unfold Deque.toList Slots.toList
  rw [hsz, hhd, hsl, List.range_succ, List.map_append, List.map_cons, List.map_nil]
  congr 1
  · apply List.map_congr_left
    intro i hi
    simp only [List.mem_range] at hi
    have hne : d.head + d.size ≠ d.head + i := by omega
    simp only [Array.getElem?_setIfInBounds_ne hne]
  · simp [Array.getElem?_setIfInBounds_self_of_lt hroom]

/-- A write at a position inside the store keeps well-formedness. -/
theorem Deque.write_wf (d : Deque α) (x : α) (hw : d.WF) (hroom : d.head + d.size < d.slots.size) :
    (d.write x).WF := by
  have hsl : (d.write x).slots = d.slots.setIfInBounds (d.head + d.size) (some x) := rfl
  have hhd : (d.write x).head = d.head := rfl
  have hsz : (d.write x).size = d.size + 1 := rfl
  refine ⟨?_, ?_⟩
  · rw [hhd, hsz, hsl, Array.size_setIfInBounds]
    omega
  · intro i hi
    rw [hsz] at hi
    rw [hhd, hsl]
    by_cases hic : i < d.size
    · have hne : d.head + d.size ≠ d.head + i := by omega
      rw [Array.getElem?_setIfInBounds_ne hne]
      exact hw.2 i hic
    · have hie : i = d.size := by omega
      subst hie
      rw [Array.getElem?_setIfInBounds_self_of_lt hroom]
      rfl

/-- A write into the room a rebuild left appends to the *original* view, since the rebuild itself does not
change it. -/
theorem Deque.write_of_rebuild (d : Deque α) (x : α) {room : Nat} (h : 0 < room) :
    ((d.rebuild room).write x).toList = d.toList ++ [x] := by
  rw [Deque.write_toList _ _ (Deque.rebuild_pos d room h), Deque.rebuild_toList]

/-- The write after a rebuild is well-formed, given that the rebuild left room. -/
theorem Deque.rebuild_write_wf (d : Deque α) (x : α) {room : Nat} (h : 0 < room) :
    ((d.rebuild room).write x).WF := by
  have hw : (d.rebuild room).WF :=
    ⟨by have := Deque.rebuild_pos d room h; omega, Deque.rebuild_dense d room⟩
  exact Deque.write_wf _ x hw (Deque.rebuild_pos d room h)

/-- **A push appends to the view.** The append lemma the model's `inject` refinement reads. -/
theorem Deque.push_toList (d : Deque α) (x : α) : (d.push x).toList = d.toList ++ [x] := by
  unfold Deque.push
  by_cases hroom : d.head + d.size < d.slots.size
  · rw [ite_eq_left hroom]
    exact Deque.write_toList d x hroom
  · rw [ite_eq_right hroom]
    by_cases hhead : 0 < d.head
    · rw [ite_eq_left hhead]
      exact Deque.write_of_rebuild d x (Nat.lt_of_lt_of_le (by decide) (Nat.le_max_left _ _))
    · rw [ite_eq_right hhead]
      exact Deque.write_of_rebuild d x (Nat.lt_of_lt_of_le (by decide) (Nat.le_max_left _ _))

/-- **A push keeps well-formedness.** -/
theorem Deque.push_wf (d : Deque α) (x : α) (hw : d.WF) : (d.push x).WF := by
  unfold Deque.push
  by_cases hroom : d.head + d.size < d.slots.size
  · rw [ite_eq_left hroom]
    exact Deque.write_wf d x hw hroom
  · rw [ite_eq_right hroom]
    by_cases hhead : 0 < d.head
    · rw [ite_eq_left hhead]
      exact Deque.rebuild_write_wf d x (Nat.lt_of_lt_of_le (by decide) (Nat.le_max_left _ _))
    · rw [ite_eq_right hhead]
      exact Deque.rebuild_write_wf d x (Nat.lt_of_lt_of_le (by decide) (Nat.le_max_left _ _))

/-- A pop that returned an element had one. -/
theorem Deque.pop_isSome_size {d : Deque α} (h : (d.pop).1.isSome) : 0 < d.size := by
  unfold Deque.pop at h
  split at h
  · assumption
  · simp at h

/-- **Density does work.** A non-empty deque can always be popped. -/
theorem Deque.pop_isSome (d : Deque α) (hw : d.WF) (hpos : 0 < d.size) : (d.pop).1.isSome := by
  have hden := hw.2 0 hpos
  simp only [Nat.add_zero] at hden
  unfold Deque.pop
  rw [ite_eq_left hpos]
  cases hm : d.slots[d.head]? with
  | none => rw [hm] at hden; simp at hden
  | some v =>
    cases v with
    | none => rw [hm] at hden; simp at hden
    | some x => simp

/-- **A pop removes from the front of the view.** -/
theorem Deque.pop_toList (d : Deque α) (hw : d.WF) (hpos : 0 < d.size) :
    ∃ x, (d.pop).1 = some x ∧ d.toList = x :: (d.pop).2.toList := by
  have hden := hw.2 0 hpos
  simp only [Nat.add_zero] at hden
  obtain ⟨k, hk⟩ : ∃ k, d.size = k + 1 := ⟨d.size - 1, by omega⟩
  unfold Deque.pop
  rw [ite_eq_left hpos]
  cases hm : d.slots[d.head]? with
  | none => rw [hm] at hden; simp at hden
  | some v =>
    cases v with
    | none => rw [hm] at hden; simp at hden
    | some x =>
      refine ⟨x, rfl, ?_⟩
      unfold Deque.toList Slots.toList
      simp only [hk, Option.join]
      rw [List.range_succ_eq_map, List.map_cons, List.map_map]
      congr 1
      · rw [show d.head + 0 = d.head by omega, hm]
        rfl
      · apply List.map_congr_left
        intro i hi
        simp only [Function.comp_apply, List.mem_range] at hi ⊢
        have hshift : (d.head + 1) + i = d.head + (i + 1) := by omega
        rw [hshift]
        have hne : d.head ≠ d.head + (i + 1) := by omega
        rw [Array.getElem?_setIfInBounds_ne hne]

/-- **A pop keeps well-formedness.** -/
theorem Deque.pop_wf (d : Deque α) (hw : d.WF) (hpos : 0 < d.size) : (d.pop).2.WF := by
  have hden := hw.2 0 hpos
  simp only [Nat.add_zero] at hden
  unfold Deque.pop
  rw [ite_eq_left hpos]
  cases hm : d.slots[d.head]? with
  | none => rw [hm] at hden; simp at hden
  | some v =>
    cases v with
    | none => rw [hm] at hden; simp at hden
    | some x =>
      have hwle : d.head + d.size ≤ d.slots.size := hw.1
      refine ⟨by simp only [Array.size_setIfInBounds]; omega, ?_⟩
      intro i hi
      have hi' : i < d.size - 1 := hi
      have hshift : (d.head + 1) + i = d.head + (i + 1) := by omega
      rw [hshift]
      have hne : d.head ≠ d.head + (i + 1) := by omega
      rw [Array.getElem?_setIfInBounds_ne hne]
      exact hw.2 (i + 1) (by omega)

/-- Popping leaves one fewer element. -/
theorem Deque.pop_size (d : Deque α) (hw : d.WF) (hpos : 0 < d.size) : (d.pop).2.size + 1 = d.size := by
  obtain ⟨x, _, hlist⟩ := Deque.pop_toList d hw hpos
  have h := congrArg List.length hlist
  simp only [List.length_cons] at h
  rw [Deque.toList_length, Deque.toList_length] at h
  omega

/-! ### Vacuity and the audit

The predicates must be shown to distinguish, or the laws above could be true of nothing. -/

/-- A fresh deque is well-formed. -/
example : (Deque.empty (α := Nat)).WF := Deque.empty_wf

/-- The empty deque's view is empty. -/
example : (Deque.empty (α := Nat)).toList = [] := by decide

/-- …and a deque whose live range runs past its store is **not** well-formed, so `WF` is not true of
everything. -/
example : ¬ (Deque.WF ({ slots := #[none], head := 0, size := 2 } : Deque Nat)) := by
  intro h
  have hle := h.1
  simp at hle

/-- The laws compose: a push is visible in the view, and the store the push built is dense. -/
example : ((Deque.empty (α := Nat)).push 7).toList = [7] := by
  rw [Deque.push_toList]; rfl

example : ((Deque.empty (α := Nat)).push 7).WF := Deque.push_wf _ _ Deque.empty_wf

/-- A drained-and-refilled deque compacts rather than growing: a pop then a push keeps the view's order. -/
example : (let d : Deque Nat := { slots := #[some 1, some 2], head := 0, size := 2 }
           (d.pop.2).push 3).toList = [2, 3] := by decide

-- The audit: the deque's reasoning is Lean's own.
#print axioms LeanIn.Deque.push_toList
#print axioms LeanIn.Deque.pop_toList
#print axioms LeanIn.Deque.push_wf
#print axioms LeanIn.Deque.pop_wf
#print axioms LeanIn.Slots.toList_ofList

end LeanIn

end
