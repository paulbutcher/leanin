import Lean
import Lean.Parser.Term
import LeanIn.Runtime.Net
import LeanIn.Runtime.Io
import LeanIn.Runtime.VM

/-!
# `asyncMachine` — split-at-`await`, liveness-driven state machines, with control flow

`asyncMachine name (c : Conn) (x : T) … := do …` compiles a connection-loop body into a per-function state
machine. The body is lowered **recursively**: pure code is inlined into the current state's step, each `await`
suspends the current state, and `if`/`recurse` become transitions between states. A **liveness analysis**
decides which variables each state carries as fields (those bound before and used after a suspension). The
first parameter `(c : Conn)` is the connection — a constant step parameter; any further parameters are
**threaded fields**: state 0 carries them, and `recurse` passes their current values back to state 0.

Grammar:
- `let x := await (e)` / `await (e)` — a suspension.
- `let x := e` / `let (a, b) := e` / a bare `e` — pure code, inlined.
- `if c then A else B` (the `else` is optional) — control flow; each branch is a nested body. A control-flow
  item in the middle of a sequence hoists the rest into a *shared* continuation state, so converging paths are
  compiled once. (`match` is the next cut, with `recvTimeout`.)
- `recurse` — jump back to state 0 (must end a path).

Effects this cut resumes: `Io.recvRaw` (auto-`Option`: `some` continues, `none` closes), `Io.sendAllRaw`,
`Io.sendRaw`, `Io.closeRaw`. Field types are inferred without a general elaboration pass: a threaded parameter
keeps its signature type, a `recvRaw`-bound variable is `ByteArray`, and a pure-bound field is read off its
use — `sendAllRaw`/`sendRaw` argument ⇒ `Array ByteArray`, `if`-condition ⇒ `Bool`, else a `Unit` placeholder.
-/

namespace LeanIn.Async
open Lean Lean.Macro Lean.Parser.Term

/-- A parsed do-item: a node in the body's tree. `contStmt` is internal — a hoisted continuation marker. -/
private inductive Item where
  | pureBind (pat : Syntax) (term : Syntax)      -- `let <pat> := e`
  | pureStmt (term : Syntax)                     -- a bare `e`
  | await (bound? : Option Name) (term : Syntax) -- `let x := await e` / `await e`
  | if_ (cond : Syntax) (then_ else_ : List Item)
  | recurse
  | contStmt (term : Term)                       -- internal: a hoisted continuation
  deriving Inhabited

/-- Recursively unwrap `doSeqIndent`/`doSeq`/`doSeqItem`/`doNested`/`null` down to the doElems. -/
private partial def doElemsOf (s : Syntax) : List Syntax :=
  match s.getKind with
  | `Lean.Parser.Term.doSeqIndent => s.getArgs.toList.flatMap doElemsOf
  | `Lean.Parser.Term.doSeq => s.getArgs.toList.flatMap doElemsOf
  | `Lean.Parser.Term.doSeqItem => s.getArgs.toList.flatMap doElemsOf
  | `Lean.Parser.Term.doNested => s.getArgs.toList.flatMap doElemsOf
  | `null => s.getArgs.toList.flatMap doElemsOf
  | _ => if s.isAtom then [] else [s]

mutual
/-- Parse a whole do-block (a `doSeq`) into items. -/
private partial def parseItems (stx : Syntax) : MacroM (List Item) :=
  (doElemsOf stx).mapM parseItem

/-- Parse one do-item, recursing into `if` branches. -/
private partial def parseItem (d : Syntax) : MacroM Item := do
  match d with
  | `(doElem| let $x:ident := await $e) => return .await (some x.getId) e
  | `(doElem| await $e) => return .await none e
  | `(doElem| let $x:ident := $e) => return .pureBind x e
  | `(doElem| let $p:term := $e) => return .pureBind p e   -- destructuring `let (a, b) := e`
  | `(doElem| if $c:term then $t:doSeq else $e:doSeq) =>
    return .if_ c (← parseItems t) (← parseItems e)
  | `(doElem| if $c:term then $t:doSeq) =>
    return .if_ c (← parseItems t) []
  | `(doElem| recurse) => return .recurse
  | `(doElem| $e:term) => return .pureStmt e
  | _ => Macro.throwError s!"asyncMachine: unsupported do-item: {d}"
end

/-- The effect an `await` runs, classified so the generator knows its resume shape and result type. -/
private inductive Eff where
  | recv                        -- `Io.recvRaw c _` → `some` ByteArray continues / `none` closes
  | sendAll (data : Term)
  | send (data : Term)
  | close
  | unknown

/-- Strip a `Term.paren` wrapper: `(e)` becomes `e`. -/
private partial def unparen (s : Syntax) : Syntax :=
  if s.getKind == `Lean.Parser.Term.paren && s.getArgs.size ≥ 2 then unparen s[1]! else s

private def classify (e : Syntax) : Eff :=
  match unparen e with
  | `(LeanIn.Runtime.Io.recvRaw $_ $_) => .recv
  | `(LeanIn.Runtime.Io.recvRaw $_) => .recv
  | `(LeanIn.Runtime.Io.sendAllRaw $_ $d) => .sendAll ⟨d⟩
  | `(LeanIn.Runtime.Io.sendRaw $_ $d) => .send ⟨d⟩
  | `(LeanIn.Runtime.Io.closeRaw $_) => .close
  | _ => .unknown

/-- The names used anywhere in a term (free variables a state might need). Dot-notation like `m.feed` is a
single compound identifier, so we collect each identifier's **root** as well as its full form — the root is the
local variable a state must carry, the full form never matches one. -/
private partial def usedNames (stx : Syntax) (acc : List Name := []) : List Name :=
  match stx with
  | .ident _ _ n _ => n :: n.getRoot :: acc
  | .node _ _ args => args.foldl (fun a s => usedNames s a) acc
  | _ => acc

/-- The names bound by a pattern (for scope and liveness). -/
private partial def patBoundNames (stx : Syntax) (acc : List Name := []) : List Name :=
  match stx with
  | .ident _ _ n _ => if n.isAnonymous || n == `_ then acc else n :: acc
  | .node _ _ args => args.foldl (fun a s => patBoundNames s a) acc
  | _ => acc

/-- All names used in a list of items (for liveness). -/
private partial def usedInItems (items : List Item) : List Name :=
  items.flatMap go
where
  go : Item → List Name
  | .pureBind _ e => usedNames e
  | .pureStmt e => usedNames e
  | .await _ e => usedNames e
  | .if_ c t e => usedNames c ++ usedInItems t ++ usedInItems e
  | .recurse => []
  | .contStmt _ => []

/-- Whether a list of items suspends anywhere (decides inline-vs-new-state for a continuation). -/
private partial def hasAwait (items : List Item) : Bool :=
  items.any fun
    | .await .. => true
    | .if_ _ t e => hasAwait t || hasAwait e
    | _ => false

/-- A variable's binding, for field-type inference. -/
private inductive Bind where
  | conn                          -- the connection (a step parameter, never a field)
  | threaded (ty : Term)          -- a threaded parameter (its signature type)
  | recvRes                       -- `recvRaw` result ⇒ `ByteArray`
  | pureB                         -- pure-bound ⇒ inferred from use

/-- A generated state: its index, its (typed) fields, and its body. -/
private structure GenState where
  idx : Nat
  fields : List (Name × Term)
  body : Term

private structure Ctx where
  name : Name
  conn : Name
  threaded : List Name          -- the threaded parameter names (state 0's fields)

private abbrev CompileM := StateT (Nat × List GenState) MacroM

/-- Extend the scope with freshly bound names. A name already in scope (a shadowing pure bind) keeps its
existing binding — and its type; a genuinely new name is `.pureB` (its type inferred from use). -/
private def extendScope (scope : List (Name × Bind)) (names : List Name) : List (Name × Bind) :=
  names.foldl (fun sc x => if sc.any (fun (n, _) => n == x) then sc else sc ++ [(x, .pureB)]) scope

private def freshIdx : CompileM Nat := do
  let (n, ss) ← get
  set (n + 1, ss)
  pure n

private def addState (s : GenState) : CompileM Unit := do
  let (n, ss) ← get
  set (n, s :: ss)

/-- The *reference* name for state `i` (`name.St.s{i}`). -/
private def stIdent (name : Name) (i : Nat) : Ident :=
  mkIdent ((Name.mkStr (name ++ `St) s!"s{i}").eraseMacroScopes)

/-- The *declaration* name for state `i` (just `s{i}`). -/
private def stLocalName (i : Nat) : Ident :=
  mkIdent ((Name.mkSimple s!"s{i}").eraseMacroScopes)

/-- Whether a pure-bound variable is used as a `sendAllRaw`/`sendRaw` data argument in the items. -/
private partial def usesSendArg (f : Name) (items : List Item) : Bool :=
  items.any go
where
  go : Item → Bool
  | .await _ e =>
    (match classify e with
     | .sendAll d | .send d => d.raw.isIdent && d.raw.getId == f
     | _ => false)
  | .if_ _ t e => usesSendArg f t || usesSendArg f e
  | _ => false

/-- Whether a pure-bound variable is used as an `if`-condition in the items. -/
private partial def usedAsCond (f : Name) (items : List Item) : Bool :=
  items.any go
where
  go : Item → Bool
  | .if_ c t e => (c.isIdent && c.getId == f) || usedAsCond f t || usedAsCond f e
  | _ => false

/-- The type of one state field, from its binding and (for pure-bound) how the continuation uses it. -/
private def fieldTypeFor (f : Name) (b : Bind) (rest : List Item) : MacroM Term := do
  match b with
  | .threaded ty => pure ty
  | .recvRes => `($(mkIdent `ByteArray))
  | .conn => Macro.throwError s!"asyncMachine: the connection `{f}` cannot be a state field"
  | .pureB =>
    if usesSendArg f rest then `(Array ByteArray)
    else if usedAsCond f rest then `($(mkIdent `Bool))
    else `($(mkIdent `Unit))

/-- A jump `name.step c (name.St.s{idx} args…)`, passing `args` (the state's live fields). -/
private def jumpTerm (ctx : Ctx) (idx : Nat) (args : List Name) : MacroM Term := do
  let step := mkIdent (ctx.name ++ `step)
  let cn := stIdent ctx.name idx
  let c := mkIdent ctx.conn
  let argTs := args.toArray.map (fun a => (mkIdent a : Term))
  if argTs.isEmpty then `($step $c $cn) else `($step $c ($cn $argTs*))

/-- The `recurse` jump: back to state 0 with the threaded parameters' current values. -/
private def recurseTerm (ctx : Ctx) : MacroM Term :=
  jumpTerm ctx 0 ctx.threaded

/-- The binding an effect's result variable gets. -/
private def resultBind (eff : Eff) : Bind :=
  match eff with
  | .recv => .recvRes
  | _ => .pureB

/-- The suspension for one effect, with continuation `cont`. -/
private def suspendTerm (ctx : Ctx) (eff : Eff) (bnd : Option Name) (cont : Term) : MacroM Term := do
  let c := mkIdent ctx.conn
  match eff with
  | .recv =>
    let bv := bnd.getD `bs
    `(LeanIn.Runtime.Io.recvRaw $c 65536 (fun
        | some $(mkIdent bv) => $cont
        | none => LeanIn.Runtime.Io.closeRaw $c))
  | .sendAll d => `(LeanIn.Runtime.Io.sendAllRaw $c $d ($cont))
  | .send d => `(LeanIn.Runtime.Io.sendRaw $c $d ($cont))
  | _ => Macro.throwError "asyncMachine: unsupported effect"

mutual
/-- Compile a list of items into the body Term of a state (or an inline continuation). Generates any
continuation states as a side effect. `scope` is the in-scope variables with their bindings. -/
private partial def compileBody (ctx : Ctx) (items : List Item) (scope : List (Name × Bind)) : CompileM Term := do
  match items with
  | [] => Macro.throwError "asyncMachine: a path does not end in `recurse` or a close"
  | .contStmt t :: rest => do
    unless rest.isEmpty do Macro.throwError "asyncMachine: internal continuation marker must end a path"
    pure t
  | .recurse :: rest => do
    unless rest.isEmpty do Macro.throwError "asyncMachine: `recurse` must end a path"
    recurseTerm ctx
  | .pureBind pat e :: rest => do
    unless pat.isIdent do
      Macro.throwError "asyncMachine: destructuring `let` is not supported yet — bind components separately (e.g. `let out := t.2.1`)"
    let inner ← compileBody ctx rest (extendScope scope (patBoundNames pat))
    `(let $(⟨pat⟩) := $(⟨e⟩); $inner)
  | .pureStmt e :: rest => do
    let inner ← compileBody ctx rest scope
    `(let _ := $(⟨e⟩); $inner)
  | .await bnd e :: rest => do
    match classify e with
    | .close =>
      unless rest.isEmpty do Macro.throwError "asyncMachine: nothing may follow `closeRaw`"
      `(LeanIn.Runtime.Io.closeRaw $(mkIdent ctx.conn))
    | .unknown => Macro.throwError "asyncMachine: unsupported effect in await"
    | eff => do
      let scope' := scope ++ bnd.toList.map (·, resultBind eff)
      let cont ← genCont ctx rest scope'
      suspendTerm ctx eff bnd cont
  | .if_ c t e :: rest => do
    let cont? ← hoistCont ctx rest scope
    let suffix := cont?.toList
    let thenT ← compileBody ctx (t ++ suffix) scope
    let elseT ← compileBody ctx (e ++ suffix) scope
    `(if $(⟨c⟩) then $thenT else $elseT)

/-- The continuation after an `await`: inline pures+`recurse`/a hoisted marker; otherwise a new state. -/
private partial def genCont (ctx : Ctx) (rest : List Item) (scope : List (Name × Bind)) : CompileM Term := do
  match rest with
  | [] => Macro.throwError "asyncMachine: an `await` has no continuation"
  | [.contStmt t] => pure t
  | _ =>
    if hasAwait rest then
      let idx ← genState ctx rest scope
      jumpTerm ctx idx (liveNames ctx rest scope)
    else
      -- pures + `recurse` (or a lone terminal): inline them.
      compileBody ctx rest scope

/-- Hoist the items after a control-flow item into a shared continuation state (so converging paths compile
once). Returns a `.contStmt` marker naming it, or `none` when there is no rest. -/
private partial def hoistCont (ctx : Ctx) (rest : List Item) (scope : List (Name × Bind)) : CompileM (Option Item) := do
  match rest with
  | [] => pure none
  | _ =>
    if hasAwait rest then
      let idx ← genState ctx rest scope
      pure (some (.contStmt (← jumpTerm ctx idx (liveNames ctx rest scope))))
    else
      pure (some (.contStmt (← compileBody ctx rest scope)))

/-- Generate a new state for `rest` (a continuation that suspends), returning its index. The state's fields
are the in-scope variables used in `rest`. -/
private partial def genState (ctx : Ctx) (rest : List Item) (scope : List (Name × Bind)) : CompileM Nat := do
  let idx ← freshIdx
  let fieldTys ← liveNames ctx rest scope |>.mapM (fun f => do
    let b := scope.lookup f |>.getD .pureB
    pure (f, ← fieldTypeFor f b rest))
  let body ← compileBody ctx rest (liveScope ctx rest scope)
  addState { idx := idx, fields := fieldTys, body := body }
  pure idx

/-- The in-scope variables used in `rest` (the live fields). Compared scope-free: the threaded parameter
declared in the signature and the same name used in the body can carry different macro scopes, which would
otherwise drop a genuinely live variable from a state's fields. -/
private partial def liveNames (_ctx : Ctx) (rest : List Item) (scope : List (Name × Bind)) : List Name :=
  let used := (usedInItems rest).map (·.eraseMacroScopes)
  scope.filter (fun (n, _) => used.contains n.eraseMacroScopes) |>.map (·.1)

/-- The scope restricted to the variables live into `rest`. -/
private partial def liveScope (ctx : Ctx) (rest : List Item) (scope : List (Name × Bind)) : List (Name × Bind) :=
  let live := liveNames ctx rest scope
  scope.filter (fun (n, _) => live.contains n)
end

/-- `asyncMachine name (c : Conn) (x : T) … := do …` — lower the body to a state machine. -/
elab "asyncMachine " n:ident " (" c:ident " : " _cty:term " )" params:bracketedBinder* " := " body:doSeq : command => do
  -- The threaded parameters (each `(x : T)`), with their signature types.
  let threadedInfo ← params.toList.mapM fun p =>
    match p.raw with
    | `(bracketedBinder| ( $x:ident : $ty:term )) => pure (x.getId, (ty : Term))
    | _ => throwError "asyncMachine: parameters must be `(x : T)`"
  let threaded := threadedInfo.map (·.1)
  let items ← Lean.Elab.liftMacroM (parseItems body)
  let ctx : Ctx := { name := n.getId, conn := c.getId, threaded := threaded }
  let initScope : List (Name × Bind) := threadedInfo.map (fun (x, ty) => (x, .threaded ty))
  -- Run the compiler, seeding state 0 as the entry (its fields are the threaded parameters).
  let s0fields ← initScope.mapM (fun (x, b) => do
    match b with
    | .threaded ty => pure (x, ty)
    | _ => pure (x, ← `($(mkIdent `Unit))))
  let compileAct : CompileM Unit := do
    let bodyT ← compileBody ctx items initScope
    addState { idx := 0, fields := s0fields, body := bodyT }
  let ((), (_n, statesRev)) ← Lean.Elab.liftMacroM (compileAct.run (1, []))
  let allStates := statesRev.reverse
  let ctors ← allStates.toArray.mapM (fun st => do
    let binders ← st.fields.toArray.mapM (fun (f, ty) => `(bracketedBinder| ($(mkIdent f) : $ty)))
    `(Lean.Parser.Command.ctor| | $(stLocalName st.idx):ident $binders*))
  let sn := mkIdent ((n.getId ++ `St).eraseMacroScopes)
  let stepn := mkIdent ((n.getId ++ `step).eraseMacroScopes)
  let runn := mkIdent ((n.getId ++ `run).eraseMacroScopes)
  let indCmd ← `(inductive $sn:ident where
    $[$ctors]*)
  Lean.Elab.Command.elabCommand indCmd
  let matchAlts ← allStates.toArray.mapM (fun st => do
    let pats := st.fields.toArray.map (fun (f, _) => (mkIdent f : Term))
    let cn := stLocalName st.idx
    let patTerm ← if pats.isEmpty then `(.$cn) else `(.$cn $pats*)
    `(matchAltExpr| | $patTerm => $(st.body)))
  let stepCmd ← `(partial def $stepn:ident ($(mkIdent c.getId) : LeanIn.Runtime.Conn) : $sn → IO Unit :=
    fun st => match st with
      $matchAlts:matchAlt*)
  Lean.Elab.Command.elabCommand stepCmd
  -- The run passes the connection and the threaded parameters to state 0.
  let s0args := threaded.toArray.map (fun x => (mkIdent x : Term))
  let s0app ← if s0args.isEmpty then `($(stIdent n.getId 0)) else `($(stIdent n.getId 0) $s0args*)
  let runCmd ← `(def $runn:ident ($(mkIdent c.getId) : LeanIn.Runtime.Conn) $params* : IO Unit :=
    $stepn $(mkIdent c.getId) $s0app)
  Lean.Elab.Command.elabCommand runCmd

end LeanIn.Async
