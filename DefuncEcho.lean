import LeanIn
import LeanIn.Runtime.Net
import LeanIn.Runtime.VM
import LeanIn.Runtime.VMHttp
import LeanIn.Runtime.SmEcho
open LeanIn

/-- The echo handler, shared across modes. -/
def reply (head : Std.Http.Request.Head) : Std.Http.Response.Head × ByteArray :=
  let body := s!"hello from leanin\nmethod={head.method} path={head.uri} version={head.version}\n".toUTF8
  let headers := Std.Http.Headers.empty.insert Std.Http.Header.Name.contentLength
      (Std.Http.Header.Value.ofString! (toString body.size))
  ({ status := .ok, version := .v11, headers }, body)

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
    monadLift (Runtime.VM.run (Runtime.VMHttp.vmServeConn c (Runtime.Clock.live hooks) 12000 {} reply))
  else if mode == "vmhttpS" then
    monadLift (Runtime.VM.run (Runtime.VMHttp.vmServeConn c (Runtime.Clock.live hooks) 400 {} reply))
  else if mode == "smecho" then
    monadLift (Runtime.SmEcho.spawnEchoStep (.reading c))
  else if mode == "smdirect" then
    monadLift (Runtime.SmEcho.directEchoStep (.reading c))
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
