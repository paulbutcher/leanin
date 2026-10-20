module

public import Std.Http.Data
public import LeanIn.Examples.Http.H1
public import LeanIn.Runtime.Net
public import LeanIn.Runtime.Clock
public import LeanIn.Runtime.Time
public import LeanIn.Runtime.VM
public import LeanIn.Async
public import LeanIn.Task.Error

public section

/-!
# The HTTP/1.1 service driver, compiled

The per-connection loop below (`drive`) is an `async`: every suspension in it is a **state of a compiled
machine**, not a closure, so a request costs a step and a raw resume rather than a `bind`, a cell and an item.
The protocol is `LeanIn.Examples.Http.H1` — our own parser and machine, in `LeanIn/Examples/Http/H1.lean` — so nothing here scans
bytes and there is no framer. The accept loops in `LeanIn.Runtime.Net` are the callers.

**The handler is a `VM`.** It may suspend — read a backend, wait on a timer — and its suspension joins this
machine through `VM.runAsync`, which starts it and parks the loop's continuation on a raw cell the handler's
final resolve fires (a handler that is pure is answered inside `pump` with no cell and no state hop). A handler
that raises is answered rather than re-raised: `VM.attempt` turns the raise into a value the loop sees, and the
machine puts `500` + `Connection: close` on the wire with `closeWithError`.

**What the deadline bounds.** `Config.stallTimeout` is passed to `recvTimeoutRaw`, so the interval between
asking the socket for bytes and bytes-or-EOF arriving is bounded. On expiry the connection ends with **nothing
written**: the peer sent no byte within the bound, so a status line would be a claim about a request that may
never have arrived. What it does not bound is a handler that never returns, `Listener.accept`, or the total time
to a complete head — a peer that sends one byte before each deadline keeps the connection alive.
-/

namespace LeanIn.Examples.Http.Server

open LeanIn.Runtime
open LeanIn.Examples.Http

/-- A request handler of ours: the parsed request head to the response head and its fully buffered body, in the
`VM`. It may suspend, and its suspension is a suspension of the connection's machine. -/
abbrev Handler := H1.Head → ByteArray → VM (H1.ResponseHead × ByteArray)

namespace Handler
/-- Lift a pure handler to an async one: its computation is just `pure`, which `pump` answers inline. -/
def ofPure (h : H1.Head → H1.ResponseHead × ByteArray) : Handler := fun head _ => pure (h head)
end Handler

/-- **The driver's own configuration**: the protocol's limits, the clock the read deadline is read from, and the
deadline itself. `h1` is handed to the machine unchanged and is the only thing that reaches it, so no clock
value can enter the encoder. -/
structure Config where
  /-- The protocol's limits, defaults and all. -/
  h1           : H1.Limits := {}
  /-- The clock `stallTimeout` is measured on. -/
  clock        : Clock
  /-- The longest a single read may wait for bytes or EOF. -/
  stallTimeout : Std.Time.Millisecond.Offset := 12000

/-- Whether a step got anywhere: it wrote bytes, or handled an event other than `needMoreData`, which the
machine re-emits on every starved step. The loop reads only when this is false, so no iteration can return to
the same machine state without writing or reading. -/
def madeProgress (before after : H1.Machine) (encoded : Nat) (events : Array H1.Event) : Bool :=
  encoded > 0 ||
  before.pos != after.pos ||
  before.chunkState != after.chunkState ||
  before.bodyDone != after.bodyDone ||
  events.any fun e => match e with
    | .needMoreData => false
    | _ => true

/-- Which of three things the pure pump stopped for. -/
inductive Stop where
  | needHandler
  | needRead
  | done
deriving Inhabited, BEq, Repr

/-- What the pump stopped with: the machine to continue from, the bytes it wants written, and -- for
`needHandler` -- the head to hand the handler.

A structure rather than an inductive with arguments, because every field the loop reads then carries its type
from the declaration. The `async` compiler infers a state field's type from its uses and errors with
the field named where uses alone cannot say, which a `match`-bound pattern hits; reading named fields
sidesteps that. -/
structure Pump where
  stop    : Stop := .done
  machine : H1.Machine := {}
  out     : Array ByteArray := #[]
  /-- A complete request whose handler suspends: the head and its buffered body. -/
  req?    : Option (H1.Head × ByteArray) := none
deriving Inhabited

/-- The connection pump, pure: step the machine, accumulate the bytes it wants written, and stop at the first
thing that needs the socket or a handler that suspends. -/
private partial def pumpGo (handler : Handler) (m : H1.Machine) (acc : Array ByteArray) : Pump :=
  if m.halted then { stop := .done, machine := m, out := acc }
  else
    let (m', step) := H1.Machine.step m
    let acc := acc ++ step.output.data
    -- A rejected head (bad syntax, too many headers, a body past the limit) is answered and the connection
    -- closed: the machine cannot return to a parseable state.
    match step.events.find? (fun e => match e with | .failed _ => true | _ => false) with
    | some (.failed e) =>
      let (status, reason) : Nat × String := match e with
        | .bodyTooLarge    => (413, "Payload Too Large")
        | .headersTooLarge => (431, "Request Header Fields Too Large")
        | .badRequest      => (400, "Bad Request")
      -- The failed step halted the machine; clearing that here lets the error response be flushed (the
      -- closing flag halts it again once the bytes are out).
      pumpGo handler ({ m'.closeWithError status reason with halted := false }) acc
    | _ =>
      -- A request is dispatched only when its framing is complete: no body (`Content-Length: 0` at
      -- `endHeaders`) or the whole body accumulated. Dispatch before the next head is parsed, or the
      -- following request's bytes would be consumed as this one's body by a later `step`.
      if m'.head?.isSome && m'.bodyDone then
        let (head, body, m'') := m'.takeRequest
        match handler head body with
        | .pure (respHead, respBody) =>
          pumpGo handler (m''.send respHead |>.sendData #[respBody] |>.userClosedBody) acc
        | _ => { stop := .needHandler, machine := m'', out := acc, req? := some (head, body) }
      else if m'.halted then { stop := .done, machine := m', out := acc }
      else if madeProgress m m' step.output.size step.events then pumpGo handler m' acc
      else { stop := .needRead, machine := m', out := acc }

/-- The pump from a fresh accumulator. -/
def pump (handler : Handler) (m : H1.Machine) : Pump := pumpGo handler m #[]

-- **The connection loop**, as a compiled machine.
--
-- `pump` runs the pure part; the output goes out verbatim; an `endHeaders` whose handler suspends is the one
-- place the handler runs, and the loop then branches on what it answered. The loop ends when the machine halts,
-- and otherwise **reads**, so the read is the default branch and the deadline covers it.
--
-- A docstring here would not parse: `async` is a command syntax registered by `elab`, and that form does
-- not take one.
async drive (c : LeanIn.Runtime.Conn) (cfg : Config) (handler : Handler) (m : LeanIn.Examples.Http.H1.Machine)
    (onClose : Except IO.Error Unit → IO Unit) := do
  let r : Pump := pump handler m
  let machine : H1.Machine := r.machine
  let out : Array ByteArray := r.out
  match r.stop with
  | .needHandler =>
    if out.size > 0 then
      let sw := await (LeanIn.Runtime.Io.sendAllRaw c out)
      match sw with
      | .error e =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        onClose (.error (if closed then e else .userError s!"{e}; and the shim refused the cleanup close"))
      | .ok _ => pure ()
    let req : H1.Head × ByteArray := r.req?.getD (default, .empty)
    let head : H1.Head := req.1
    let body : ByteArray := req.2
    let answered := await (LeanIn.Runtime.VM.runAsync (VM.attempt (handler head body)))
    match answered with
    | .ok (respHead, body) =>
      let m := H1.Machine.send machine respHead |>.sendData #[body] |>.userClosedBody
      recurse
    | .error _ =>
      let m := H1.Machine.closeWithError machine 500
      recurse
  | .needRead =>
    if out.size > 0 then
      let sw := await (LeanIn.Runtime.Io.sendAllRaw c out)
      match sw with
      | .error e =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        onClose (.error (if closed then e else .userError s!"{e}; and the shim refused the cleanup close"))
      | .ok _ => pure ()
    -- A live clock's deadline is a slot the driver sweeps on its own poll timeout; a harness clock's is an
    -- armed instant the virtual driver advances to, and it must be retired exactly.
    if cfg.clock.swept then
      let rt := await (LeanIn.Runtime.Io.recvStallRaw c cfg.stallTimeout 65536)
      match rt with
      | none =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        onClose (if closed then .ok () else .error (.userError "Io.closeRaw: the loop refused the connection's close submission"))
      | some (.error e) =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        onClose (.error (if closed then e else .userError s!"{e}; and the shim refused the cleanup close"))
      | some (.ok none) =>
        let m := H1.Machine.noMoreInput machine
        recurse
      | some (.ok (some bs)) =>
        let m := H1.Machine.feed machine bs
        recurse
    else
      let rt := await (LeanIn.Runtime.Io.recvTimeoutRaw c cfg.clock.schedule cfg.stallTimeout 65536)
      match rt with
      | none =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        onClose (if closed then .ok () else .error (.userError "Io.closeRaw: the loop refused the connection's close submission"))
      | some (.error e) =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        onClose (.error (if closed then e else .userError s!"{e}; and the shim refused the cleanup close"))
      | some (.ok none) =>
        let m := H1.Machine.noMoreInput machine
        recurse
      | some (.ok (some bs)) =>
        let m := H1.Machine.feed machine bs
        recurse
  | .done =>
    if out.size > 0 then
      let sw := await (LeanIn.Runtime.Io.sendAllRaw c out)
      match sw with
      | .error e =>
        let closed := await (LeanIn.Runtime.Io.closeRaw c)
        onClose (.error (if closed then e else .userError s!"{e}; and the shim refused the cleanup close"))
      | .ok _ => pure ()
    let closed := await (LeanIn.Runtime.Io.closeRaw c)
    onClose (if closed then .ok () else .error (.userError "Io.closeRaw: the loop refused the connection's close submission"))

/-- **Serve one connection**: run the compiled loop from a fresh machine built from `cfg.h1` alone. The
connection outlives a single exchange -- it ends when the machine halts, or when the peer closes or stalls past
`cfg.stallTimeout`. The returned computation completes only when the machine's terminal close fires `onClose`:
`Conn.serve` owns the socket by the body's lifetime, so the body must span the connection, not its first
suspension. One `Join` cell per connection -- never one per request. The cell carries the connection's
**outcome**: a clean close is `.ok`, a transport failure is the error, so a reset is never reported as a
success -- the shape the accept loops' registries and drains already account by. -/
def serveConn (cfg : Config) (c : Conn) (handler : Handler) : Task.EAsync IO.Error Unit :=
  ⟨fun k ctx => do
    let cell ← (Task.Join.new : IO (Task.Join (Except IO.Error Unit)))
    drive.run c cfg handler ({ limits := cfg.h1 } : H1.Machine)
      (fun r => Task.Join.resolve cell ctx.resumeShared r)
    (Task.Async.await (show Task.Task (Except IO.Error Unit) from ⟨cell, ctx.cancel⟩)).step
      (fun r ctx' => k r ctx') ctx⟩

end LeanIn.Examples.Http.Server
end
