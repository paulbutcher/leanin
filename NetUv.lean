-- The libuv port of the I/O drop, and the shape the real path will have.
--
-- Our own loop, driven one iteration at a time from this Lean thread, so every libuv callback fires here. None of
-- them enters Lean: they queue events (and leave read bytes in place) for the loop below to drain. `uv_run`,
-- `uv_accept`, `uv_read_start` and `uv_write` are the same calls on kqueue and IOCP, so this file is portable
-- where the epoll shim is not.
--
--   lake build netuv && ./.lake/build/bin/netuv <port> <requests>
import Std

@[extern "np_uv_start"] opaque npUvStart (port : UInt32) : IO UInt32
@[extern "np_uv_run_once"] opaque npUvRunOnce : IO UInt32
@[extern "np_uv_events"] opaque npUvEvents : IO (Array UInt64)
@[extern "np_uv_take"] opaque npUvTake (idx : UInt32) : IO ByteArray
@[extern "np_uv_write"] opaque npUvWrite (idx : UInt32) (b : ByteArray) : IO UInt32
@[extern "np_uv_close"] opaque npUvClose (idx : UInt32) : IO Unit
@[extern "np_uv_stop"] opaque npUvStop : IO Unit

def main (args : List String) : IO UInt32 := do
  let port := (args[0]?).bind (·.toNat?) |>.getD 8092
  let want := (args[1]?).bind (·.toNat?) |>.getD 1000000
  let bound ← npUvStart port.toUInt32
  if bound == 0 then
    IO.println "netuv: could not bind"
    return 1
  IO.println s!"netuv: listening on 127.0.0.1:{bound} (libuv {port})"
  let resp : ByteArray :=
    "HTTP/1.1 200 OK\r\nContent-Length: 17\r\nConnection: close\r\n\r\nhello from netuv\n".toUTF8
  let mut served : Nat := 0
  let mut iterations : Nat := 0
  let mut stopping := false
  while served < want && !stopping do
    let active ← npUvRunOnce
    iterations := iterations + 1
    let evs ← npUvEvents
    if evs.isEmpty && active == 0 then
      break
    let mut i : Nat := 0
    while i + 1 < evs.size do
      let kind := evs[i]!
      let idx := evs[i + 1]!.toUInt32
      if kind == 1 then
        -- a complete request: read it and answer
        let _ ← npUvTake idx
        let _ ← npUvWrite idx resp
      else if kind == 2 then
        -- the response is out and the peer may be closed
        npUvClose idx
        served := served + 1
      else if kind == 3 then
        -- the peer closed (the readiness probe does exactly this)
        npUvClose idx
      else if kind == 5 then
        -- a signal asked us to stop, so report what was served
        stopping := true
      i := i + 2
  npUvStop
  IO.println s!"netuv: done, served={served} in {iterations} loop iterations"
  return 0
