import Std

/-!
# The shared inject queue

The one queue every carrier shares: an external wake, and every worker's overflow, arrive here
(`docs/tokio-map.md` §2, `docs/interface.md` §3). It is deliberately **not** a field of
`LeanIn.Model.Pool`: a worker's own ring and LIFO slot are written under that worker's lock, while this
list is written under the shared cell's lock, and the model keeps the two locks' worth of state in two
declarations so the shared one is not updated by a step that owns only a worker's lock.

The queue is a FIFO — `push` appends at the back, `pop` takes from the front — and it is unbounded, so
there is no capacity law to state. What a `List` gives here is the conservation law `LeanIn.Model.Multi`
composes over every carrier: `push_length` and `pop_length` say the shared queue neither loses nor
invents work when one item crosses it.

The model keeps the specification's `++ [x]`: a list's O(1) end is the front, so the append walks the
list, and that cost is the *implementation's* to pay (`LeanIn.Data.Deque`, `docs/PERFORMANCE.md` §4.3).
-/

namespace LeanIn

namespace Model

/-- The shared inject queue: appended at the back, taken from the front, unbounded. -/
structure Inject (α : Type) where
  /-- The items held, in arrival order. -/
  items : List α := []
deriving Inhabited, Repr

/-- Append at the back — the specification's own `++ [x]`. -/
def Inject.push (j : Inject α) (x : α) : Inject α := { items := j.items ++ [x] }

/-- Take from the front. -/
def Inject.pop (j : Inject α) : Option α × Inject α :=
  match j.items with
  | x :: rest => (some x, { items := rest })
  | []        => (none, j)

/-- **A push adds exactly one item.** -/
theorem push_length (j : Inject α) (x : α) : (j.push x).items.length = j.items.length + 1 := by
  simp [Inject.push]

/-- **A pop removes exactly one item when it returns one, and nothing when it does not.** The
conservation law of the shared queue on its own. -/
theorem pop_length (j : Inject α) :
    (j.pop).2.items.length + (if (j.pop).1.isSome then 1 else 0) = j.items.length := by
  cases hi : j.items with
  | cons x rest => simp [Inject.pop, hi]
  | nil => simp [Inject.pop, hi]

/-- A non-empty queue hands something out. This is what lets a `take` from the shared queue be
*decided* by whether the queue holds anything, rather than by a second counter. -/
theorem pop_returns_if_present (j : Inject α) (h : j.items ≠ []) : (j.pop).1.isSome := by
  unfold Inject.pop
  cases hi : j.items with
  | cons x rest => rfl
  | nil => exact absurd hi h

-- The audit: the shared queue's laws rest on nothing beyond Lean's own axioms.
#print axioms LeanIn.Model.push_length
#print axioms LeanIn.Model.pop_length
#print axioms LeanIn.Model.pop_returns_if_present

end Model

end LeanIn
