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

/-- A request handler: the parsed request head to the response head and its fully-buffered body. Pure — the
benchmark's `reply`/`static` are. -/
abbrev Handler := VMHttp.PureHandler

/-- The server's configuration: the protocol's limits (`h1`, which carries `maxMessages` and friends), the
clock the stall deadline is read from, and the deadline itself. Mirrors `Runtime.Http.Config`. -/
structure Config where
  /-- The protocol's limits, defaults and all. -/
  h1           : Std.Http.Protocol.H1.Config := {}
  /-- The clock `stallTimeout` is measured on. -/
  clock        : Clock
  /-- The longest a single read may wait for bytes or EOF before the connection is ended. -/
  stallTimeout : Std.Time.Millisecond.Offset := 12000

/-- The H1 connection driver, pure: step the machine, run the handler on `endHeaders`, and keep stepping while
it makes progress, returning the updated machine, the accumulated output to write, and whether it halted. This
is `Runtime.Http.drive`'s pure core — the part between the socket effects — folded into one function so
`asyncMachine` suspends only on the reads and writes. -/
partial def pump (handler : Handler) (m : Std.Http.Protocol.H1.Machine .receiving) :
    Std.Http.Protocol.H1.Machine .receiving × Array ByteArray × Bool :=
  go m #[]
where
  go (m : Std.Http.Protocol.H1.Machine .receiving) (acc : Array ByteArray) :
      Std.Http.Protocol.H1.Machine .receiving × Array ByteArray × Bool :=
    if m.halted then (m, acc, true)
    else
      let (m', step) := m.step
      let acc := acc ++ step.output.data
      let m'' := VMHttp.processEvents m' step.events handler
      if m''.halted then (m'', acc, true)
      else if VMHttp.madeProgress step.output.size step.events then go m'' acc
      else (m'', acc, false)

asyncMachine serveConn (c : LeanIn.Runtime.Conn) (clock : LeanIn.Runtime.Clock) (stall : Std.Time.Millisecond.Offset) (handler : Handler) (m : Std.Http.Protocol.H1.Machine .receiving) := do
  let t := pump handler m
  let m := t.1
  let out := t.2.1
  let halted := t.2.2
  if out.size > 0 then
    await (LeanIn.Runtime.Io.sendAllRaw c out)
  if halted then
    await (LeanIn.Runtime.Io.closeRaw c)
  else
    let r := await (LeanIn.Runtime.Io.recvTimeoutRaw c clock.schedule stall 65536)
    match r with
    | none => await (LeanIn.Runtime.Io.closeRaw c)
    | some none =>
      let m := m.noMoreInput
      recurse
    | some (some bs) =>
      let m := m.feed bs
      recurse

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
