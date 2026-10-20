module

import Std
import Std.Async.TCP
import LeanIn.Runtime.Io
import LeanIn.Runtime.Leaf
import LeanIn.Runtime.Time
import LeanIn.Task.Error
import LeanIn.Task.Registry
import LeanIn.Task.Sync


public section
/-!
# Sockets on our carriers

`interface.md` §4 said the leaf operations stay in `Std.Async` and are reached across W1's seam. That is true of
the **client** half only today. The server's listener and connections are `LeanIn/Runtime/Io.lean`'s: one of our
own libuv loops, driven by a stock task, parks each operation on one of our `Join` cells and resolves it through
the runtime's inject — so no promise bridge stands between a socket completion and the carrier that resumes on
it. This file keeps the operations' names, types and meanings, so `Http.lean` and the accept loops below did not
change; what changed is what they run on.

The client stays on `Std.Async` deliberately. `connect` and `echoConn` are the outbound half, exercising a
library this task does not replace, and SC19's own client is `Std.Async`'s — a client that is not ours is what
makes the thread identities it measures mean anything.

**The two connection names.** `Conn` is the *server-side* connection: what an accept loop hands to a
per-connection body, and what `Http.serveConn` drives. `ClientConn` is `Std.Async.TCP.Socket.Client`, which is
what `connect` returns.

**A connection's lifetime is its body's.** The accept loops run every body through `Conn.serve`, which closes the
connection when the body is done with it — on its return and on its failure. The socket has to go either way: the
peer's read ends at the FIN, and the shim's slot comes back, which is what the service's own obligations count an
admitted connection by. It is also what the `Std.Async` half gave for free, where a dropped socket was collected
and its handle closed; here the shim holds the handle, so whoever handed the connection over says so.

**The accept loop is still ours, and that is W10's finding, not W9's convenience.** `Std.Http.Server` cannot give
us one: its own loop runs as a stock `Task` (`Server.lean:193`), which is the observation SC19's carrier clause
reports. So the loop lives here, over a listener whose accepts come back as our computations.

**Every operation returns a failure rather than raising it.** This is the first place `EAsync` is the right
answer rather than a convenience: a client that closes a connection mid-request, or a socket that reports
ECONNRESET, is the *normal* case for a server, so the error travels with the value. A panic here would take the
process down for an event a server meets every day.

**What the leaf registry no longer sees.** `Runtime.Hooks` counts registrations on `Std.Async` leaves. A server
operation on this path registers no leaf — it parks on a cell the libuv loop resolves — so `Runtime.pending`
does not count a parked read or write any more. The `hooks` parameter below is carried because the accept loops
and `Http.lean` pass it and their signatures are theirs; nothing in the server half reads it. The client half
does, exactly as before.
-/

namespace LeanIn.Runtime

/-- Bind and listen. Port `0` asks the OS for an ephemeral one, which `sockName` then reports — binding before
anything is served, so a client that connects immediately meets a listening socket rather than a race.

`backlog` is carried for the callers' signature and does not reach the shim, whose listen backlog is libuv's own
argument; the address must be the IPv4 loopback one, because the shim binds `127.0.0.1` and refuses any other
address loudly rather than binding a different one than the caller asked for. -/
def Listener.bind (addr : Std.Net.SocketAddress) (backlog : UInt32 := 1024) : IO Listener :=
  Io.startListener addr backlog

/-- The address actually bound, which is what a client needs when the port was ephemeral. -/
def Listener.sockName (l : Listener) : IO Std.Net.SocketAddress :=
  Io.sockName l

/-- **Accept, awaited as one of ours.** A failing accept is a value: a listener whose loop has been retired is
not an abort. -/
def Listener.accept (l : Listener) (_hooks : Hooks) : Task.EAsync IO.Error Conn :=
  Io.accept l

/-- **Accept without waiting**, for `serveUntilStopped`'s poll: a connection the loop has already accepted and
no accept has claimed, or `none`. -/
def Listener.tryAccept (l : Listener) : IO (Option Conn) :=
  Io.tryAccept l

/-- Receive up to `size` bytes. `none` is end of stream, which is not a failure. -/
def Conn.recv (c : Conn) (_hooks : Hooks) (size : UInt64 := 65536) : Task.EAsync IO.Error (Option ByteArray) :=
  Io.recv c size

/-- Send one buffer. -/
def Conn.send (c : Conn) (_hooks : Hooks) (data : ByteArray) : Task.EAsync IO.Error Unit :=
  Io.send c data

/-- Send several buffers **as one write**. The buffers go out in order inside one submission, so the peer reads
one segment; the shim copies them into the block the write request owns, which is what it already does for a
single buffer. -/
def Conn.sendAll (c : Conn) (_hooks : Hooks) (data : Array ByteArray) : Task.EAsync IO.Error Unit :=
  Io.sendAll c data

/-- Shut down the write side: how a server says it is done with a connection. The shim closes the connection's
handle on that completion, so the peer reads the end of stream before the socket goes. -/
def Conn.shutdown (c : Conn) (_hooks : Hooks) : Task.EAsync IO.Error Unit :=
  Io.shutdown c

/-- A connected socket as its *client* sees it: `Std.Async`'s, which is what `connect` yields. -/
abbrev ClientConn := Std.Async.TCP.Socket.Client

/-- **Connect, awaited as one of ours.** A client operation, and the one the error channel's own test needs: a
refused connect is the ordinary way to make a socket operation fail on purpose.

The socket is made through `ofAsync`/`ofIO` rather than by lifting the `IO` action implicitly: do-notation
inserts a lift for a nested action but not for a bind here, so the two steps are written out. -/
def connect (hooks : Hooks) (addr : Std.Net.SocketAddress) : Task.EAsync IO.Error ClientConn := do
  let c ← Task.EAsync.ofAsync (Task.Async.ofIO Std.Async.TCP.Socket.Client.mk)
  let _ ← awaitAsyncE hooks (Std.Async.TCP.Socket.Client.connect c addr)
  return c

/-- **Echo a connection until the peer stops, then shut it down.**

A socket failure ends the connection rather than the loop: the peer going away mid-stream is the case this
signature exists for, and the alternative — what the first version of this file did — is a process that dies
because a client closed a socket.

`partial` because a connection has no bound, and `Async` is `Inhabited`, which is what lets this be recursion
rather than a `while` in a monad with no way to say it terminates. -/
partial def echoConn (hooks : Hooks) (c : ClientConn) : Task.EAsync IO.Error Unit := do
  try
    match ← awaitAsyncE hooks (Std.Async.TCP.Socket.Client.recv? c 65536) with
    | none      => awaitAsyncE hooks (Std.Async.TCP.Socket.Client.shutdown c)
    | some ch   => awaitAsyncE hooks (Std.Async.TCP.Socket.Client.send c ch); echoConn hooks c
  catch _ => pure ()

/-- **Run a connection's body and then close its connection.**

A connection's lifetime is its body's: when the body returns — or fails — the socket goes, so the peer's read
ends at the FIN and the shim's slot comes back. This is the rule the accept loops below assume, and the rule the
service's own obligations are stated over (`Service.NoDrop` and `Service.Bounded` count an admitted connection
as gone when its body is done with it), and it is where the sockets of the `Std.Async` half got it: a dropped
socket was collected and its handle closed, so a body that simply returned released its connection without
saying so. Here the shim holds the handle, so the loop that handed the connection over says so on the body's
behalf. `Http.serveConn` already shuts its write side down, and the close is a no-op for a connection that is
already closing.

The close runs on both paths, before the body's own failure travels: if the close itself fails — the loop is
going away, which is the larger fact and unrecoverable either way — that failure is the one reported. -/
private def Conn.serve (body : Conn → Task.EAsync IO.Error Unit) (c : Conn) : Task.EAsync IO.Error Unit := do
  let bodyFailed? ← try
      body c
      pure none
    catch e => pure (some e)
  monadLift (Io.close c)
  match bodyFailed? with
  | none   => pure ()
  | some e => throw e

/-- **An accept loop of our own.** It accepts `n` connections — one task each, through `background`, which
against `MonadAsync` is the local route, so a connection stays on the carrier its accept ran on — and then
awaits them all.

Awaiting is what makes "the executor holds nothing afterwards" an observation rather than a guess, so this is
the loop the scenario uses. A fire-and-forget variant existed here and was deleted rather than kept: nothing
called it, and an untested export is worse than a missing one, since the driver that will want it can add it
back where it is used.

Each body runs through `Conn.serve`, so the connection is closed when the body is done with it. -/
def serveNJoin (hooks : Hooks) (l : Listener) (n : Nat) (body : Conn → Task.EAsync IO.Error Unit) :
    Task.EAsync IO.Error Unit := do
  let reg : Task.Registry (Except IO.Error Unit) ← monadLift (Task.Registry.new (α := Except IO.Error Unit))
  for _ in List.range n do
    let client ← Listener.accept l hooks
    let h ← Task.MonadAsync.spawn (Conn.serve body client)
    monadLift (Task.Registry.add reg h)
  Task.EAsync.ofAsync (Task.Registry.joinAll reg)

/-- The accept-until-stop loop of `serveUntilStopped`: one attempt per iteration, with the accepted connection's
handle registered in a `Registry`, until `Executor.isStopping` — then `Registry.drain` awaits everything still
registered, so the stop is a drain *operation* rather than a `List.forM` in the loop. -/
private partial def serveUntilStoppedLoop (hooks : Hooks) (e : Sched.Executor Task.Item cap) (l : Listener)
    (clock : Clock) (interval : Std.Time.Millisecond.Offset) (body : Conn → Task.EAsync IO.Error Unit)
    (reg : Task.Registry (Except IO.Error Unit)) : Task.EAsync IO.Error Unit := do
  if ← monadLift (e.isStopping : IO Bool) then
    Task.EAsync.ofAsync (do
      Task.Registry.drain reg)
  else
    match ← monadLift (Listener.tryAccept l : IO (Option Conn)) with
    | some client =>
      let h ← Task.MonadAsync.spawn (Conn.serve body client)
      monadLift (Task.Registry.add reg h)
      serveUntilStoppedLoop hooks e l clock interval body reg
    | none =>
      Task.EAsync.ofAsync (do
        sleep clock interval)
      serveUntilStoppedLoop hooks e l clock interval body reg

/-- **Accept until the executor is stopping, then finish what is in flight and return.**

A drain in the shape W5 asks for: stop accepting, let the connections already accepted run to completion, and
return only *after* awaiting them — so a driver returns with nothing held rather than with work it will never
run. It takes the executor because the decision it makes is the executor's own flag; `Executor.isStopping` is the
reading, and there is no second copy of it here. The outstanding handles are a `Registry`; the stop is
`Registry.drain`, which takes the membership, clears it, and awaits each handle *outside* the lock.

The trailing `hs` parameter is the loop's initial membership, kept so the signature is unchanged; callers pass
`[]`, and it is seeded into the registry once, at entry, before the loop runs.

**It is exercised, and by a scenario rather than a diagnostic.** The first version of the diagnostic for this loop
— connect, send, stop, read — hung, and the hang was the driver's rather than the loop's: `blockOn` ended as
soon as the pool was empty and the executor was stopping, which abandons a continuation registered on a leaf.
Fixed there, `tests/executor-contract.sh SC10` runs this loop to completion and reads `served=1 echoed=yes
inFlightAfter=0 pendingHooks=0`.

**Polling is the cost, and it is W7's absence showing through.** `tryAccept` is a non-blocking attempt — a read
of the loop's already-accepted connections, not a parked accept — so the loop sleeps `interval` between attempts
instead of parking on a selector. The accept-versus-shutdown choice is exactly a `select`, the interface has none
yet, and the price of not having it is a drain whose latency is one poll interval rather than immediate. That
interval is awaited on `Clock.live hooks`, built once here, so the loop's timing stays the production clock's:
this signature offers no harness-driven drain. -/
def serveUntilStopped (hooks : Hooks) (e : Sched.Executor Task.Item cap) (l : Listener)
    (interval : Std.Time.Millisecond.Offset) (body : Conn → Task.EAsync IO.Error Unit)
    (hs : List (Task.Task (Except IO.Error Unit))) : Task.EAsync IO.Error Unit := do
  let reg : Task.Registry (Except IO.Error Unit) ← monadLift (Task.Registry.new (α := Except IO.Error Unit))
  monadLift (hs.forM (fun h => Task.Registry.add reg h))
  let clock := Clock.live hooks
  serveUntilStoppedLoop hooks e l clock interval body reg

/-- **An accept loop that waits on the listener instead of polling it.** `Listener.accept` parks until a
connection arrives, so this loop neither sleeps between attempts nor delays an accept by a poll interval: where
`serveUntilStopped` answers a connection up to `interval` late and spends a sleep on every tick, this one is
woken by the arrival itself.

It has **no stop condition**, and that is a consequence rather than an oversight: a parked accept is withdrawn
only by retiring the loop it belongs to (`Io.startListener`'s retire step, when another listener is bound), and
nothing in this loop can retire its own loop — this surface has no `close` on a listener, and `shutdown` is the
write side of a connection, not a listener's. A programme that must stop accepting uses `serveUntilStopped`,
whose stop is a drain over a registry; this loop is for a server that runs until the process is killed.

Each accepted connection is spawned on the accepting worker's own route, and its handle is dropped: nothing
awaits it, and the connection's own end is what retires it. The body runs through `Conn.serve`, so the connection
is closed when the body is done with it. -/
partial def serveForever (hooks : Hooks) (l : Listener) (body : Conn → Task.EAsync IO.Error Unit) :
    Task.EAsync IO.Error Unit := do
  let c ← Listener.accept l hooks
  let _ ← Task.MonadAsync.spawn (Conn.serve body c)
  serveForever hooks l body

/-- The admission loop of `serveBounded`: one admission per iteration, with the handles accepted so
far accumulated, until exactly `n` connections have been served — then every handle is awaited.

A permit is taken before the accept and never after it. `tryAcquire` first, because a free permit must
not pay for a park that would wake it at once; `acquire` only when the bound is full, which parks this
step and resumes it holding the permit, so the accept below always runs with one. A failing accept
releases the permit it was holding before the failure travels, so no failure path can drain the bound. -/
private partial def serveBoundedLoop (hooks : Hooks) (l : Listener) (sem : Task.Sync.Semaphore)
    (serve : Conn → Task.EAsync IO.Error Unit) (i n : Nat)
    (reg : Task.Registry (Except IO.Error Unit)) : Task.EAsync IO.Error Unit := do
  if i ≥ n then
    Task.EAsync.ofAsync (Task.Registry.drain reg)
  else
    if ← monadLift (Task.Sync.Semaphore.tryAcquire sem) then pure ()
    else Task.EAsync.ofAsync (Task.Sync.Semaphore.acquire sem)
    let client ← try
      Listener.accept l hooks
    catch e =>
      -- The release delivers the waiters it wakes on the *releasing* step's own route, so the route of this
      -- step travels with the call.
      let push ← Task.EAsync.ofAsync Task.Async.push
      monadLift (Task.Sync.Semaphore.release sem push)
      throw e
    let h ← Task.MonadAsync.spawn (serve client)
    monadLift (Task.Registry.add reg h)
    serveBoundedLoop hooks l sem serve (i + 1) n reg

/-- **An accept loop with an admission bound.** It serves exactly `n` connections while admitting at
most `bound` at a time: with the bound full the loop parks on the semaphore rather than admitting, and
a connection's permit is released when its body ends, so a place in the bound is returned by every
route out of a body.

That release is the point, and it is total. The body's outcome is read into a value first — `try` for its own
return, a `catch` for its failure — then the permit is released, and only then does a failure travel on. So the
release runs on every path a body can take, none skipped, including the failure. That total is over the body's own
return and failure paths only: under cancellation `Item.fire` skips the whole step, so the release is skipped too
— the limit `decisions.md` D15 records. The accepted connection's own failure is the ordinary case here (a
socket's failure is the value `EAsync` carries), so a body returning `.error` must give its permit back rather
than leaking it; a leak would only *reduce* admissions and so never break the bound, but it would degrade the
bound to a hint.

Every handle is awaited before the function returns (the shape `serveNJoin` has), so a driver returns
with nothing held. The signature matches `serveNJoin`'s, so a caller moves between the two loops by
changing one line; the loop assigns no connection id, so the payload id a body reads is the client's
and an admission ordinal can never be confused with a connection identity.

The semaphore is the right primitive and not merely an available one: the bound is the service's own
obligation, and `Task.Sync.Semaphore` is built for this shape — a wake is a hint and a permit is taken
in the waiter's own step, so the loop can never be handed a permit it then skips. -/
def serveBounded (hooks : Hooks) (l : Listener) (bound : Nat) (n : Nat)
    (body : Conn → Task.EAsync IO.Error Unit) : Task.EAsync IO.Error Unit := do
  let sem ← monadLift (Task.Sync.Semaphore.new bound)
  let serve (c : Conn) : Task.EAsync IO.Error Unit := do
    let push ← Task.EAsync.ofAsync Task.Async.push
    -- The body's own failure is what this reports, and the permit comes back *before* it travels, so no path
    -- out of a body can leak one. `Conn.serve` closes the connection on the same two paths.
    let failed? ← try
        Conn.serve body c
        pure none
      catch e => pure (some e)
    monadLift (Task.Sync.Semaphore.release sem push)
    match failed? with
    | none   => pure ()
    | some e => throw e
  let reg : Task.Registry (Except IO.Error Unit) ← monadLift (Task.Registry.new (α := Except IO.Error Unit))
  serveBoundedLoop hooks l sem serve 0 n reg

/-- **The loopback address a scenario binds**: `127.0.0.1` and a port. -/
def loopback (port : UInt16 := 0) : Std.Net.SocketAddress :=
  .v4 ⟨⟨#v[127, 0, 0, 1]⟩, port⟩

end LeanIn.Runtime

end
