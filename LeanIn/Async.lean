import Lean
import Lean.Parser.Term
import LeanIn.Runtime.Net
import LeanIn.Runtime.Io
import LeanIn.Runtime.VM

/-!
# `asyncMachine` — split-at-`await`, liveness-driven state machines

`asyncMachine name (c : Conn) := do …` compiles a connection-loop body into a per-function state machine: the
body is **split at each `await`**, the pure code between awaits is inlined into the current state's step, and a
**liveness analysis** decides which variables each state must carry as fields (those bound before an `await`
and used after it). This is the representation `SmEchoSM` proved by hand — concrete per-function types, data
continuations, raw delivery — generated rather than written out.

Grammar for this first milestone (the connection-loop shape):
- `let x := await (e)` — a suspension binding `x` to the effect's result.
- `await (e)` — a suspension, ignoring the result.
- `let x := e` — a pure binding (including records; liveness carries them whole or fieldwise).
- `recurse` — jump back to the first state.

The effects this cut knows how to resume: `Io.recvRaw` (auto-`Option` branch: `some` continues, `none`
closes), `Io.sendAllRaw`, `Io.closeRaw`, `RawCell.await`, and an `IO Unit` spawn call. More effects and richer
control flow (`if`/`match`/`loop`) are the following milestones.
-/

namespace LeanIn.Async
open Lean Lean.Macro Lean.Parser.Term

/-- A parsed do-item: whether it suspends, what it binds, and its term. -/
private structure PItem where
  isAwait : Bool
  bound? : Option Name
  term : Syntax

/-- Recursively unwrap `doSeqIndent`/`doSeq`/`doSeqItem`/`doNested`/`null` down to the doElems. The exact
nesting varies with how the `do` block was written (`:= do` vs a bare `do`), so descend rather than assume. -/
private partial def doElemsOf (s : Syntax) : List Syntax :=
  match s.getKind with
  | `Lean.Parser.Term.doSeqIndent => s.getArgs.toList.flatMap doElemsOf
  | `Lean.Parser.Term.doSeq => s.getArgs.toList.flatMap doElemsOf
  | `Lean.Parser.Term.doSeqItem => s.getArgs.toList.flatMap doElemsOf
  | `Lean.Parser.Term.doNested => s.getArgs.toList.flatMap doElemsOf
  | `null => s.getArgs.toList.flatMap doElemsOf
  | _ => if s.isAtom then [] else [s]

/-- Collect and classify the do-items of the body. -/
private def parse (stx : Syntax) : MacroM (List PItem) :=
  (doElemsOf stx).mapM itemOf
where
  itemOf (d : Syntax) : MacroM PItem := do
    match d with
    | `(doElem| let $x:ident := await $e) => return { isAwait := true, bound? := some x.getId, term := e }
    | `(doElem| await $e) => return { isAwait := true, bound? := none, term := e }
    | `(doElem| let $x:ident := $e) => return { isAwait := false, bound? := some x.getId, term := e }
    | `(doElem| $e:term) => return { isAwait := false, bound? := none, term := e }
    | _ => Macro.throwError "asyncMachine: unsupported do-item"

/-- One segment of the split: the pure items that run in this state, then the `await` that suspends it
(`none` for the trailing segment that just halts or recurses). -/
private structure Segment where
  pures : List PItem        -- pure bindings/statements, inlined into the step
  susp : Option PItem      -- the suspension that ends the segment
  isRecurse : Bool           -- the trailing segment jumps back to state 0

/-- **Split at `await`.** Pure items accumulate into the current segment; an `await` closes it and starts the
next; `recurse` marks the trailing segment. -/
private def split (items : List PItem) : List Segment :=
  let rec go (cur : List PItem) (acc : List Segment) : List PItem → List Segment
    | [] =>
      let tail : Segment := { pures := cur.reverse, susp := none, isRecurse := false }
      acc.reverse.concat tail
    | i :: rest =>
      if i.isAwait then
        go [] ({ pures := cur.reverse, susp := some i, isRecurse := false } :: acc) rest
      else if i.term.isOfKind ``Lean.Parser.Term.do then
        go [] acc rest
      else if isRecurseTok i.term then
        let tail : Segment := { pures := cur.reverse, susp := none, isRecurse := true }
        acc.reverse.concat tail
      else
        go (i :: cur) acc rest
  go [] [] items
where
  isRecurseTok (t : Syntax) : Bool :=
    match t with
    | `(recurse) => true
    | _ => false

/-- **Liveness**: the names used anywhere in a term (free variables a state might need). -/
private partial def usedNames (stx : Syntax) (acc : List Name := []) : List Name :=
  match stx with
  | .ident _ _ n _ => n :: acc
  | .node _ _ args => args.foldl (fun a s => usedNames s a) acc
  | _ => acc

/-- The variables live *into* a segment: bound in an earlier segment and used in this one or any later one. -/
private def liveInto (segs : List Segment) (i : Nat) : List Name :=
  let boundBefore := (segs.take i).flatMap (fun s => (s.pures.flatMap (fun p => p.bound?.toList)) ++ s.susp.toList.flatMap (fun p => p.bound?.toList))
  let usedAfter := (segs.drop i).flatMap (fun s => s.pures.flatMap (fun p => usedNames p.term) ++ s.susp.toList.flatMap (fun p => usedNames p.term))
  boundBefore.filter (fun b => usedAfter.contains b)

/-- The effect a segment's `await` runs, classified so the generator knows its resume shape and the type it
produces. -/
private inductive Eff where
  | recv                        -- `Io.recvRaw c _` → ByteArray (some) / close (none)
  | sendAll (data : Term)     -- `Io.sendAllRaw c data`
  | send (data : Term)        -- `Io.sendRaw c data`
  | close                       -- `Io.closeRaw c`
  | unknown

/-- Strip a `Term.paren` wrapper: `(e)` becomes `e`. The `await (effect)` form always wraps the effect in
parens, so classify on the inside. -/
private partial def unparen (s : Syntax) : Syntax :=
  if s.getKind == `Lean.Parser.Term.paren && s.getArgs.size ≥ 2 then unparen s[1]! else s

private def classify (e : Syntax) : Eff :=
  match unparen e with
  | `(LeanIn.Runtime.Io.recvRaw $_ $_) => .recv
  | `(LeanIn.Runtime.Io.recvRaw $_) => .recv
  | `(LeanIn.Runtime.Io.sendAllRaw $_ $d) => .sendAll d
  | `(LeanIn.Runtime.Io.sendRaw $_ $d) => .send d
  | `(LeanIn.Runtime.Io.closeRaw $_) => .close
  | _ => .unknown

/-- Field type for a variable bound by an `await`: recv produces `ByteArray`. -/
private def fieldType (e : Syntax) : MacroM Term := do
  match classify e with
  | .recv => `($(mkIdent `ByteArray))
  | _ => `($(mkIdent `Unit))

/-- One state: its index, the (typed) fields it carries, its segment, and the index it jumps to next. -/
private structure SState where
  idx : Nat
  fields : List (Name × Syntax)   -- (var name, effect term it came from — for its type)
  seg : Segment

/-- The *reference* name for state `i` (`name.St.s{i}`, for constructor applications and patterns). -/
private def stIdent (name : Name) (i : Nat) : Ident :=
  let r := (Name.mkStr (name ++ `St) s!"s{i}").eraseMacroScopes
  mkIdent r

/-- The *declaration* name for state `i` (just `s{i}` — the inductive qualifies it to `name.St.s{i}`). -/
private def stLocalName (i : Nat) : Ident :=
  mkIdent ((Name.mkSimple s!"s{i}").eraseMacroScopes)

/-- Build one constructor declaration for the state inductive. -/
private def ctorOf (name : Name) (st : SState) : MacroM (TSyntax `Lean.Parser.Command.ctor) := do
  let cn := stLocalName st.idx
  let binders ← st.fields.toArray.mapM (fun (f, e) => do
    let ty ← fieldType e
    `(bracketedBinder| ($(mkIdent f) : $ty)))
  `(Lean.Parser.Command.ctor| | $cn:ident $binders*)

/-- The constructor *application* `name.step c (name.St.s{j} args…)` jumping to state `j` with `args`. -/
private def jumpTo (name : Name) (conn : Name) (j : Nat) (args : List Name) : MacroM Term := do
  let step := mkIdent (name ++ `step)
  let cn := stIdent name j
  let argTs := args.toArray.map (fun a => (mkIdent a : Term))
  if argTs.isEmpty then
    `($step $(mkIdent conn) $cn)
  else
    `($step $(mkIdent conn) ($cn $argTs*))

/-- The match arm for one state. `prefix` runs first (pure items inlined); then the suspension resumes to the
next state. -/
private def armOf (name : Name) (conn : Name) (st : SState) (nextIdx : Nat) (nextLive : List Name) : MacroM (TSyntax `Lean.Parser.Term.matchAltExpr) := do
  let c := mkIdent conn
  let pats := st.fields.toArray.map (fun (f, _) => (mkIdent f : Term))
  let cn := stLocalName st.idx
  let susp := st.seg.susp.getD { isAwait := true, bound? := none, term := Syntax.missing }
  let patTerm ← if pats.isEmpty then `(.$cn) else `(.$cn $pats*)
  match classify susp.term with
  | .recv =>
    let bv := susp.bound?.getD `bs
    -- The target's live vars (`nextLive`, from liveInto of `nextIdx`) already include `bv` when `bv` is used
    -- later, so passing `nextLive` alone avoids doubling it; the continuation binds `bv` to fill that field.
    let body ← jumpTo name conn nextIdx nextLive
    `(matchAltExpr| | $patTerm => LeanIn.Runtime.Io.recvRaw $c 65536 (fun
        | some $(mkIdent bv) => $body
        | none => LeanIn.Runtime.Io.closeRaw $c))
  | .sendAll d =>
    let body ← jumpTo name conn nextIdx nextLive
    `(matchAltExpr| | $patTerm => LeanIn.Runtime.Io.sendAllRaw $c $d ($body))
  | .send d =>
    let body ← jumpTo name conn nextIdx nextLive
    `(matchAltExpr| | $patTerm => LeanIn.Runtime.Io.sendRaw $c $d ($body))
  | .close =>
    `(matchAltExpr| | $patTerm => LeanIn.Runtime.Io.closeRaw $c)
  | .unknown => Macro.throwError "asyncMachine: unsupported effect in await"

/-- The effect term a live variable was bound by (for its field type). -/
private def sourceEffect (segs : List Segment) (f : Name) : Syntax :=
  match segs.find? (fun s => (s.pures ++ s.susp.toList).any (fun p => p.bound? == some f)) with
  | some s => (s.pures ++ s.susp.toList).find? (fun p => p.bound? == some f) |>.map (·.term) |>.getD Syntax.missing
  | none => Syntax.missing

/-- `asyncMachine name (c : Conn) := do …` — split at `await`, liveness, generate the machine. -/
elab "asyncMachine " n:ident " (" c:ident " : " _ty:term " )" " := " body:doSeq : command => do
  let items ← Lean.Elab.liftMacroM (parse body)
  let segs := split items
  -- The suspending segments are the states (a trailing recurse/non-await tail is not its own state).
  let states := segs.filter (fun s => s.susp.isSome)
  let lastIdx := states.length - 1
  let trailingRecurse := segs.any (fun s => s.isRecurse)
  let ctors ← states.toArray.mapIdxM (fun i st =>
    let live := liveInto states i
    let fields := live.map (fun f => (f, sourceEffect states f))
    Lean.Elab.liftMacroM (ctorOf n.getId { idx := i, fields := fields, seg := st }))
  let arms ← states.toArray.mapIdxM (fun i st =>
    let nextIdx := if i == lastIdx && trailingRecurse then 0 else i + 1
    let nextLive := if nextIdx == 0 then [] else liveInto states nextIdx
    Lean.Elab.liftMacroM (armOf n.getId c.getId { idx := i, fields := liveInto states i |>.map (fun f => (f, sourceEffect states f)), seg := st } nextIdx nextLive))
  let sn := mkIdent ((n.getId ++ `St).eraseMacroScopes)
  let stepn := mkIdent ((n.getId ++ `step).eraseMacroScopes)
  let runn := mkIdent ((n.getId ++ `run).eraseMacroScopes)
  let indCmd ← `(inductive $sn:ident where
    $[$ctors]*)
  Lean.Elab.Command.elabCommand indCmd
  let stepCmd ← `(partial def $stepn:ident ($(mkIdent c.getId) : LeanIn.Runtime.Conn) : $sn → IO Unit :=
    fun st => match st with
      $arms:matchAlt*)
  Lean.Elab.Command.elabCommand stepCmd
  Lean.Elab.Command.elabCommand (← `(def $runn:ident ($(mkIdent c.getId) : LeanIn.Runtime.Conn) : IO Unit :=
    $stepn $(mkIdent c.getId) $(stIdent n.getId 0)))

end LeanIn.Async
