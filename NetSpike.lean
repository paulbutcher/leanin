-- The spike for a direct I/O path: our own descriptors, our own epoll, and the poll thread is a *Lean* thread.
-- No Std.Async, no IO.Promise, no Task anywhere on the I/O path — a completion is just Lean code resuming after
-- `npEpollWait` returned.
--
--   cc -c -O2 -o .lake/build/netpoll.o c/netpoll.c -I $(lean --print-prefix)/include
--   lake build netspike && ./.lake/build/bin/netspike [port]
import Std

@[extern "np_listen"] opaque npListen (port : UInt16) : IO UInt32
@[extern "np_epoll_create"] opaque npEpollCreate : IO UInt32
@[extern "np_epoll_add"] opaque npEpollAdd (epfd : UInt32) (fd : UInt32) (tag : UInt64) : IO UInt32
@[extern "np_epoll_del"] opaque npEpollDel (epfd : UInt32) (fd : UInt32) : IO UInt32
@[extern "np_epoll_wait"] opaque npEpollWait (epfd : UInt32) (timeoutMs : UInt32) : IO (Array UInt64)
@[extern "np_accept"] opaque npAccept (lfd : UInt32) : IO UInt32
@[extern "np_recv"] opaque npRecv (fd : UInt32) (buf : ByteArray) (max : UInt32) : IO UInt32
@[extern "np_send"] opaque npSend (fd : UInt32) (buf : ByteArray) (len : UInt32) : IO UInt32
@[extern "np_close"] opaque npClose (fd : UInt32) : IO Unit

/-- The response, built once: a complete HTTP/1.1 reply. -/
def response : ByteArray :=
  "HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\nhello from netspike\n".toUTF8

def main (args : List String) : IO UInt32 := do
  let port : UInt16 := match args with
    | p :: _ => (p.toNat?.getD 8090).toUInt16
    | [] => 8090
  let lfd ← npListen port
  if lfd == 0 then
    IO.println "netspike: listen failed"
    return 1
  let epfd ← npEpollCreate
  let added ← npEpollAdd epfd lfd 0
  IO.println s!"netspike: listening on 127.0.0.1:{port} | listener={lfd} epfd={epfd} registered={added}"
  let ready ← IO.mkRef (#[] : Array UInt64)
  let inbuf ← IO.mkRef (ByteArray.mk (Array.replicate 65536 (0 : UInt8)))
  let mut served : Nat := 0
  while served < 1000000 do
    let tags ← npEpollWait epfd 120000
    ready.set tags
    if tags.isEmpty then
      IO.println "netspike: nothing ready within the bound"
      break
    for tag in tags do
      if tag == 0 then
        -- the listener: accept every pending connection and register it under its own descriptor
        let mut more := true
        while more do
          let cfd ← npAccept lfd
          if cfd == 0 then
            more := false
          else
            let _ ← npEpollAdd epfd cfd cfd.toUInt64
            IO.println s!"netspike: accepted fd {cfd}"
      else
        let fd := tag.toUInt32
        let got ← npRecv fd (← inbuf.get) 65536
        if got == 0 || got == 0xFFFFFFFF then
          IO.println s!"netspike: fd {fd} closed (recv={got})"
          let _ ← npEpollDel epfd fd
          npClose fd
        else
          let _ ← npSend fd response response.size.toUInt32
          let _ ← npEpollDel epfd fd
          npClose fd
          served := served + 1
          IO.println s!"netspike: fd {fd} read {got} bytes, answered, served={served}"
  IO.println s!"netspike: done, served={served}"
  return 0
