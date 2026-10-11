import LeanIn.Model.Multi
import LeanIn.Model.Scheduler

/-!
# The pure-model oracle for a scripted executor trace

The independent side of `tests/executor-contract.md`'s refinement check. It runs the *fixed script* below
against the pure model — `LeanIn.Model.Multi` for the composition of a worker's own queue with the shared
inject — and prints one canonical record per step:

```
model|trace|op=<name>|pos=<n>|task=<identity>|out=<outcome>
```

The records are computed by the model's own functions, never written out as an expected text, so a run that
matches the executor's `exec|trace|` records is evidence that the executor's transactions agree with the
model, not that two copies of a fixture agree with each other.

## The projection

Every step is one *modelled transaction*, not a change to one model at a time. A submit places a task in
worker `0`'s own queue (`Multi.pushLocal`); an external delivery goes to the shared inject and unparks a
parked worker in the same step (`Multi.pushShared`) — the two are different transactions now, which is what
the multi-carrier runtime's queues are; a take serves worker `0`'s own queue when it holds anything and the
shared inject otherwise, matching the order the driver's take has; a park is `Multi.park`, refused while
either holds anything.

`Multi.held` and `Multi.taken` are then the same quantities the executor's `Snapshot` reports — every
worker's own queue plus the shared list, and every place an item can be taken from — so the two sides of a
comparison refer to the same work rather than to two independent counters. `step` checks the projection's
conservation law after every step and reports a broken projection as a defect of this fixture (a nonzero exit
and a stderr message) rather than as a comparison result, because a trace from a misaligned projection would
be no evidence either way.

The script is shared with the executor: both advance the same ordered operations at the same positions over
the same task identities, so the records are comparable pairwise.
-/

namespace ModelOracle

open LeanIn Model

/-- The composition the script advances: one worker (index `0`, the driver's) and the shared inject, at the
pool capacity the executor under test is built with. -/
abbrev State := Multi Nat 256

/-- One step of the fixed script. -/
inductive Op where
  /-- Submit a computation to worker `0`'s own queue. -/
  | submit (task : Nat)
  /-- An external event delivers a computation: the shared inject, and a parked worker woken with it. -/
  | enqueue (task : Nat)
  /-- The carrier takes the next item of work. -/
  | take
  /-- The carrier tries to park. -/
  | park

/-- The fixed script: nine ordered operations, at positions 0 to 8.

Position 2 parks while two items are held and is refused; positions 3 and 4 take them; position 5 parks
again and is granted; position 6 is the external delivery that unparks the carrier; positions 7 and 8 take
that delivery and then find nothing. -/
def script : List Op :=
  [ .submit 0, .submit 1, .park, .take, .take, .park, .enqueue 2, .take, .take ]

/-- The number of steps the script must contain. A shorter script would quietly weaken the comparison by
giving the executor fewer records to match, so the length is checked rather than assumed. -/
def scriptSteps : Nat := 9

/-- Worker `0`'s pool: the driver's own queue. -/
def worker0 (m : State) : Pool Nat := (m.workers[0]?).getD (emptyPool Nat)

/-- Whether a pool's own queue holds anything: the decision the driver's take makes first. A `Bool` rather
than `Pool.HasWork`, because the script's records are computed with `if`. -/
def busy (p : Pool Nat) : Bool := !p.ring.isEmpty || p.lifo.isSome

/-- **Which item a take serves.** Worker `0`'s own queue first — its LIFO slot while the tick's allowance
lasts, the ring's front after that — and the shared list's front when the pool holds nothing, which is the
order the driver's take has. The model's transitions do not return the item, so the record reads it off the
state the take was decided from. -/
def takenItem (st : State) : Option Nat :=
  if busy (worker0 st) then
    if (worker0 st).lifoPolls < (worker0 st).lifoCap ∧ (worker0 st).lifo.isSome then (worker0 st).lifo
    else (worker0 st).ring.head?
  else st.inject.items.head?

/-- One canonical operation record: operation, input position, task identity, returned outcome. -/
def record (op : String) (pos : Nat) (task : String) (out : String) : String :=
  s!"op={op}|pos={pos}|task={task}|out={out}"

/-- The projection relation every step must preserve: everything ever submitted is still held somewhere or
was taken. -/
def aligned (st : State) : Bool := st.held + st.taken == st.pushed

/-- The broken projection, if any, as the text this fixture reports it with. -/
def alignError (st : State) : Option String :=
  if aligned st then none
  else some s!"held={st.held} + taken={st.taken} ≠ pushed={st.pushed}"

/-- Accept a step's result, or reject it when the projection no longer relates the two models. -/
def checked (st : State) (op : String) (pos : Nat) (rec : String) : Except String (State × String) :=
  match alignError st with
  | none   => .ok (st, rec)
  | some e => .error s!"{op} at pos {pos}: {e}"

/-- Advance one step: one modelled transaction, its canonical record, and the projection check. -/
def step (st : State) (o : Op) (pos : Nat) : Except String (State × String) :=
  match o with
  | .submit t =>
    match st.pushLocal 0 t with
    | some m => checked m "submit" pos (record "submit" pos (toString t) s!"inflight{m.held}")
    | none   => .error s!"submit at pos {pos}: worker 0 refused a local push"
  | .enqueue t =>
    let m := st.pushShared t
    checked m "enqueue" pos (record "enqueue" pos (toString t) s!"inflight{m.held}")
  | .take =>
    -- the driver's take: worker 0's own queue first, the shared list after it
    let taken :=
      if busy (worker0 st) then st.takeLocal 0
      else if st.inject.items ≠ [] then st.takeShared
      else none
    match taken with
    | some m =>
      checked m "take" pos
        (record "take" pos (toString ((takenItem st).getD 0)) s!"taken{m.taken}")
    | none =>
      checked st "take" pos (record "take" pos "-" "none")
  | .park =>
    match st.park 0 with
    | some m =>
      checked m "park" pos (record "park" pos "-" s!"parked{m.parkedCount}")
    | none =>
      checked st "park" pos (record "park" pos "-" "none")

/-- The scripted run: every state after its step, paired with the record that step produced. -/
def runSteps : State → Nat → List Op → Except String (List (State × String))
  | _, _, [] => .ok []
  | st, pos, o :: rest =>
    match step st o pos with
    | .error e => .error e
    | .ok (st', r) =>
      match runSteps st' (pos + 1) rest with
      | .error e => .error e
      | .ok more => .ok ((st', r) :: more)

/-- The states and records the fixed script produces, in order. -/
def run : Except String (List (State × String)) := runSteps (Multi.initial Nat 256 1) 0 script

end ModelOracle

open ModelOracle

/-- Print one `model|trace|` line per record.

A broken projection or a script of the wrong length is a defect of this fixture rather than a comparison
result, so each is reported on stderr and exits nonzero. -/
def main : IO UInt32 := do
  match run with
  | .error e =>
    IO.eprintln s!"model oracle: the scripted projection is not aligned: {e}"
    return 2
  | .ok steps =>
    if steps.length != scriptSteps then
      IO.eprintln s!"model oracle: the script produced {steps.length} records, expected {scriptSteps}"
      return 2
    for s in steps do
      IO.println s!"model|trace|{s.2}"
    return 0
