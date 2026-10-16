import LeanIn
import LeanIn.Runtime.Net
import LeanIn.Runtime.VM
import LeanIn.Runtime.VMHttp
import LeanIn.Runtime.SmEcho
import LeanIn.Runtime.HttpServer
import LeanIn.Async
open LeanIn

asyncMachine amEcho (c : LeanIn.Runtime.Conn) := do
  let req := await (LeanIn.Runtime.Io.recvRaw c 65536)
  await (LeanIn.Runtime.Io.sendAllRaw c #[req])
  recurse

/-- Stateless H1 respond: feed the request bytes to a fresh machine, then step + run the handler until the
machine stops making progress, returning the accumulated output (the response). Correct when each read
delivers a complete request — the benchmark's sequential keep-alive requests; a partial read would need the
machine threaded across iterations (the control-flow/liveness follow-up), since a fresh machine loses it. -/
partial def process (handler : Runtime.VMHttp.PureHandler) (bs : ByteArray) : Array ByteArray :=
  go (({ config := {} } : Std.Http.Protocol.H1.Machine .receiving).feed bs) #[]
where
  go (m : Std.Http.Protocol.H1.Machine .receiving) (acc : Array ByteArray) : Array ByteArray :=
    if m.halted then acc
    else
      let (m', step) := m.step
      let acc := acc ++ step.output.data
      let m'' := Runtime.VMHttp.processEvents m' step.events handler
      if m''.halted then acc
      else if Runtime.VMHttp.madeProgress step.output.size step.events then go m'' acc
      else acc

/-- The echo handler, shared across modes. -/
def reply (head : Std.Http.Request.Head) : Std.Http.Response.Head × ByteArray :=
  let body := s!"hello from leanin\nmethod={head.method} path={head.uri} version={head.version}\n".toUTF8
  let headers := Std.Http.Headers.empty.insert Std.Http.Header.Name.contentLength
      (Std.Http.Header.Value.ofString! (toString body.size))
  ({ status := .ok, version := .v11, headers }, body)

/-- An async variant used to exercise the handler suspension path: wait 10 ms on the server clock, then reply. -/
def delayedReply (clock : Runtime.Clock) (head : Std.Http.Request.Head) :
    Runtime.VM (Std.Http.Response.Head × ByteArray) := do
  Runtime.VM.sleep clock 10
  pure (reply head)

asyncMachine amHttp (c : LeanIn.Runtime.Conn) := do
  let bs := await (LeanIn.Runtime.Io.recvRaw c 65536)
  let out := process reply bs
  await (LeanIn.Runtime.Io.sendAllRaw c out)
  recurse

-- A loop as a state machine: send `msg0..msg2` (each an `await`), then close — the loop counter `i` is the
-- loop state's field, threaded across iterations. Exercises `while` in `asyncMachine`.
asyncMachine amLoop (c : LeanIn.Runtime.Conn) := do
  let i : Nat := 0
  while i < 3 do
    await (LeanIn.Runtime.Io.sendAllRaw c #[s!"msg{i}\n".toUTF8])
    let i := i + 1
  await (LeanIn.Runtime.Io.closeRaw c)

-- `for` over an array: send each element (an await per element), then close.
asyncMachine amFor (c : LeanIn.Runtime.Conn) := do
  for x in (#[s!"a\n".toUTF8, s!"b\n".toUTF8, s!"c\n".toUTF8] : Array ByteArray) do
    await (LeanIn.Runtime.Io.sendAllRaw c #[x])
  await (LeanIn.Runtime.Io.closeRaw c)

-- `while` with `break`: send 0, 1, then break out and close.
asyncMachine amBreak (c : LeanIn.Runtime.Conn) := do
  let i : Nat := 0
  while i < 10 do
    if i == 2 then break
    await (LeanIn.Runtime.Io.sendAllRaw c #[s!"{i}\n".toUTF8])
    let i := i + 1
  await (LeanIn.Runtime.Io.closeRaw c)

-- `while` with `continue`: send the odd numbers 1,3,5, skipping even by `continue`.
asyncMachine amContinue (c : LeanIn.Runtime.Conn) := do
  let i : Nat := 0
  while i < 5 do
    let i := i + 1
    if i % 2 == 0 then continue
    await (LeanIn.Runtime.Io.sendAllRaw c #[s!"{i}\n".toUTF8])
  await (LeanIn.Runtime.Io.closeRaw c)

/-- CPS echo: read, write back, recurse — every step through the `Join`-cell delivery (park, `Item`, carrier). -/
partial def cpsEcho (hooks : Runtime.Hooks) (c : Runtime.Conn) : Task.EAsync IO.Error Unit := do
  try
    match ← Runtime.Conn.recv c hooks with
    | none    => Runtime.Conn.shutdown c hooks
    | some bs => Runtime.Conn.send c hooks bs; cpsEcho hooks c
  catch _ => pure ()

/-- VM echo: the *same* logic, written in the defunctionalizing `VM` monad with ordinary `do`. -/
partial def vmEcho (c : Runtime.Conn) : Runtime.VM Unit := do
  match ← Runtime.VM.recv c with
  | some bs => Runtime.VM.send c bs; vmEcho c
  | none    => Runtime.VM.close c

partial def acceptLoop (hooks : Runtime.Hooks) (l : Runtime.Listener) (mode : String) :
    Task.EAsync IO.Error Unit := do
  let c ← Runtime.Listener.accept l hooks
  if mode == "raw" then
    monadLift (Runtime.Io.defuncEcho c)
  else if mode == "vm" then
    monadLift (Runtime.VM.run (vmEcho c))
  else if mode == "vmhttp" then
    monadLift (Runtime.VM.run (Runtime.VMHttp.vmServeConn c (Runtime.Clock.live hooks) 1500 {} reply))
  else if mode == "vmhttpS" then
    monadLift (Runtime.VM.run (Runtime.VMHttp.vmServeConn c (Runtime.Clock.live hooks) 400 {} reply))
  else if mode == "smecho" then
    monadLift (Runtime.SmEcho.spawnEchoStep (.reading c))
  else if mode == "smdirect" then
    monadLift (Runtime.SmEcho.directEchoStep (.reading c))
  else if mode == "async" then
    monadLift (amEcho.run c)
  else if mode == "amhttp" then
    monadLift (amHttp.run c)
  else if mode == "loop" then
    monadLift (amLoop.run c)
  else if mode == "for" then
    monadLift (amFor.run c)
  else if mode == "brk" then
    monadLift (amBreak.run c)
  else if mode == "cont" then
    monadLift (amContinue.run c)
  else if mode == "serveconn" then
    -- `maxMessages` bumped far past the default 100 so a keep-alive connection is not closed mid-benchmark
    -- (Node applies no per-connection request cap); the H1 machine threads the count across requests.
    monadLift (Runtime.HttpServer.serveConn.run c (Runtime.Clock.live hooks) 12000 (Runtime.HttpServer.Handler.ofPure reply) ({ config := { maxMessages := 1000000000 } } : Std.Http.Protocol.H1.Machine .receiving))
  else if mode == "asynchandler" then
    let clock := Runtime.Clock.live hooks
    monadLift (Runtime.HttpServer.serveConn.run c clock 12000 (delayedReply clock) ({ config := { maxMessages := 1000000000 } } : Std.Http.Protocol.H1.Machine .receiving))
  else
    let _ ← Task.MonadAsync.spawn (cpsEcho hooks c)
  acceptLoop hooks l mode

def main (args : List String) : IO UInt32 := do
  let port := (args.head?.bind (·.toNat?)).getD 8080
  let mode := args.getD 1 "cps"
  let hooks ← Runtime.Hooks.new
  let l ← Runtime.Listener.bind (Runtime.loopback port.toUInt16)
  let e ← Sched.Executor.new LeanIn.Task.Item 256 1
  let _ : Except IO.Error Unit ← Runtime.run e (acceptLoop hooks l mode)
  return 0
