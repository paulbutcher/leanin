import Std.Http.Protocol.H1
import LeanIn.Runtime.Net
import LeanIn.Runtime.Io
import LeanIn.Runtime.Clock
import LeanIn.Runtime.VMHttp
import LeanIn.Async

/-!
# `LeanIn.Runtime.HttpServer` — an HTTP/1.1 server on the `asyncMachine` engine

A replacement surface for `Std.Http.Server`, built on the defunctionalizing state-machine engine: each
connection's read → feed → step → dispatch → write loop is `serveConn`, an `asyncMachine` that compiles the H1
driver to a per-function state machine resumed by raw delivery. The H1 machine is **threaded** across requests
(a field of the states), so partial reads, pipelining and keep-alive are handled by the machine itself; the
stall deadline (`recvTimeout`) closes a peer that sends nothing, exactly as `Runtime.Http.serveConn` does.

The handler here is **pure** (`Head → Response.Head × ByteArray`): it runs inside `pump`, the pure step +
`endHeaders`-dispatch loop, so it cannot suspend. A suspending handler is the task-effect milestone — the
handler's own `await` becomes a suspension point in the same machine. For the large class of handlers that are
pure compute over the request head (static content, routing, serialisation) this is the whole API.

## Use

```
let hooks ← Runtime.Hooks.new
let l ← Runtime.Listener.bind (Runtime.loopback 8080)
let cfg : Runtime.HttpServer.Config := { clock := Runtime.Clock.live hooks }
Runtime.run e (Runtime.HttpServer.serve hooks cfg l myHandler)
```
-/

namespace LeanIn.Runtime.HttpServer

/-- A request handler: the parsed request head to a computation producing the response head and its
fully-buffered body. The computation is a **`VM`** — it may suspend (read a backend, wait on a timer), and its
suspension becomes a suspension in the connection's state machine via `VM.runAsync`. A handler that is pure
compute over the head lifts with `Handler.ofPure`. -/
abbrev Handler := Std.Http.Request.Head → VM (Std.Http.Response.Head × ByteArray)

namespace Handler
/-- Lift a pure handler (`Head → Response.Head × ByteArray`) to an async one: its computation is just `pure`. -/
def ofPure (h : VMHttp.PureHandler) : Handler := fun head => pure (h head)
end Handler

/-- The server's configuration: the protocol's limits (`h1`, which carries `maxMessages` and friends), the
clock the stall deadline is read from, and the deadline itself. Mirrors `Runtime.Http.Config`. -/
structure Config where
  /-- The protocol's limits, defaults and all. -/
  h1           : Std.Http.Protocol.H1.Config := {}
  /-- The clock `stallTimeout` is measured on. -/
  clock        : Clock
  /-- The longest a single read may wait for bytes or EOF before the connection is ended. -/
  stallTimeout : Std.Time.Millisecond.Offset := 12000

/-- What `pump` stopped for: the machine produced `out` bytes and then either hit an `endHeaders` whose handler
**suspends** (the `vm` to await), ran dry (`needRead`), or halted (`done`). A handler that is pure is answered
inline inside `pump` and never surfaces here — only a suspending one is returned, so the common case pays
nothing for the async machinery being available. -/
inductive PumpResult where
  | needHandler (m : Std.Http.Protocol.H1.Machine .receiving) (out : Array ByteArray)
      (head : Std.Http.Request.Head)
  | needRead (m : Std.Http.Protocol.H1.Machine .receiving) (out : Array ByteArray)
  | done (m : Std.Http.Protocol.H1.Machine .receiving) (out : Array ByteArray)

instance : Inhabited PumpResult :=
  ⟨.done ({ config := {} } : Std.Http.Protocol.H1.Machine .receiving) #[]⟩

/-- The H1 connection driver, pure. `handler head` is evaluated here: a **pure** handler's response is queued
and pumping continues (no state hop, no cell — the common case); a handler that **suspends** is returned as
`.needHandler` for `serveConn` to await, its computation resumed on the loop thread. -/
partial def pump (handler : Handler) (m : Std.Http.Protocol.H1.Machine .receiving) : PumpResult :=
  go m #[]
where
  go (m : Std.Http.Protocol.H1.Machine .receiving) (acc : Array ByteArray) : PumpResult :=
    if m.halted then .done m acc
    else
      let (m', step) := m.step
      let acc := acc ++ step.output.data
      match step.events.find? (fun e => match e with | .endHeaders _ => true | _ => false) with
      | some (.endHeaders head) =>
        match handler head with
        | .pure (respHead, body) =>
          go (m'.send respHead |>.sendData #[Std.Http.Chunk.ofByteArray body] |>.userClosedBody) acc
        | _ => .needHandler m' acc head
      | _ =>
        if m'.halted then .done m' acc
        else if VMHttp.madeProgress step.output.size step.events then go m' acc
        else .needRead m' acc

asyncMachine serveConn (c : LeanIn.Runtime.Conn) (clock : LeanIn.Runtime.Clock) (stall : Std.Time.Millisecond.Offset) (handler : Std.Http.Request.Head → LeanIn.Runtime.VM (Std.Http.Response.Head × ByteArray)) (m : Std.Http.Protocol.H1.Machine .receiving) := do
  let r := pump handler m
  match r with
  | .needHandler m out head =>
    if out.size > 0 then
      await (LeanIn.Runtime.Io.sendAllRaw c out)
    let resp := await (LeanIn.Runtime.VM.runAsync (handler head))
    let m := m.send resp.1 |>.sendData #[Std.Http.Chunk.ofByteArray resp.2] |>.userClosedBody
    recurse
  | .needRead m out =>
    if out.size > 0 then
      await (LeanIn.Runtime.Io.sendAllRaw c out)
    let rt := await (LeanIn.Runtime.Io.recvTimeoutRaw c clock.schedule stall 65536)
    match rt with
    | none => await (LeanIn.Runtime.Io.closeRaw c)
    | some none =>
      let m := m.noMoreInput
      recurse
    | some (some bs) =>
      let m := m.feed bs
      recurse
  | .done m out =>
    if out.size > 0 then
      await (LeanIn.Runtime.Io.sendAllRaw c out)
    await (LeanIn.Runtime.Io.closeRaw c)

/-- The accept loop: take a connection, set its state machine running, and accept the next. `serveConn.run`
returns at the first suspension (the machine then runs on the loop thread), so connections proceed
concurrently. -/
partial def serveLoop (hooks : Hooks) (cfg : Config) (l : Listener) (handler : Handler) :
    Task.EAsync IO.Error Unit := do
  let c ← Listener.accept l hooks
  monadLift (serveConn.run c cfg.clock cfg.stallTimeout handler
    ({ config := cfg.h1 } : Std.Http.Protocol.H1.Machine .receiving))
  serveLoop hooks cfg l handler

/-- **Serve**: accept connections on `l` and drive each with the compiled `serveConn`. This is the
`Std.Http.Server.serve` analogue on the `asyncMachine` engine. -/
def serve (hooks : Hooks) (cfg : Config) (l : Listener) (handler : Handler) : Task.EAsync IO.Error Unit :=
  serveLoop hooks cfg l handler

end LeanIn.Runtime.HttpServer
