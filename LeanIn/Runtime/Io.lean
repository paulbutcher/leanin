import Std
import LeanIn.Task.Basic
import LeanIn.Task.Error

/-!
# The I/O path on our own libuv loop

This is the server-side socket layer: a listener and a connection whose operations are completed by *our own*
libuv loop, parked on the runtime's own `Join` cells, so a completion is delivered through the runtime's inject
rather than across the promise bridge. It replaces the leaf seam on this path — `Runtime.Leaf.awaitAsyncE` and
the `Std.Async` leaf behind it. The bridge is what it replaces, and the numbers behind that decision are in the
run notes: awaiting an already-resolved promise through the seam measures 99 µs where the same shape inside our
own machinery measures 11 µs.

**C never enters Lean.** `c/netuv.c` records events and leaves read bytes in the connection's own buffer; the
loop thread drains that queue with `npUvEvents` and `npUvTake` and delivers what it finds. No libuv callback
calls back into Lean, and no Lean code runs on a thread Lean did not create.

**The loop thread is a stock task, not a carrier.** `uv_run` blocks, so a carrier here would stall the executor
it belongs to. The thread is `IO.asTask … .dedicated`, and it runs `npUvRunOnce` until the shim reports the loop
drained. Everything it delivers it delivers as work: resolving a cell calls the registering step's own
`ctx.resumeShared`, which is `Runtime.sharedPush e` — the inject — so the resumed step runs on a carrier, and a
handler keeps running on the carrier its connection was accepted on.

**Where the executor comes from, and why it is not a parameter.** A step's `Ctx` carries `resumeShared`, and
`Runtime.Ctx.at` builds it as `sharedPush e` — the same function for every worker of a given executor. So the
operations take the shared route from the step that submits them, which is where every other delivery in this
runtime takes it (`Runtime/Leaf.lean`'s leaf continuations, `Runtime/Blocking.lean`'s completions, the harness
clock's fire), and the loop thread never needs the executor itself: what it holds is the (cell, push) pair the
submitting step parked. Threading an `Executor` through these signatures would be a second way of reading one
function.

**One listener at a time, and that is the shim's shape rather than a preference.** `c/netuv.c` owns one loop and
one listening handle, so `startListener` retires a running loop before it binds its own: the previous loop's
thread is asked to stop, drained, and joined. A listener whose loop has been retired fails its parked operations
loudly rather than hanging — a connection or an accept from it is a caller error, and it is reported as one.

**The loop thread outlives the work, so a program that bound a listener stops it before returning.** `stop` is
that call. Lean's task manager waits for every dedicated task when the runtime shuts down, and the loop thread is
one: left running it is parked in `uv_run` for as long as its listener exists, so the process finishes its work
and then waits in the runtime's own shutdown for a thread that has nothing to do. There is no exit hook in this
toolchain to register instead, and a process-level signal cannot be used here — Lean's signal machinery owns
those dispositions (see `c/netuv.c`'s header and `stop`'s docstring).

**What a stop does to what is parked.** Every parked operation is a cell in one mutex-guarded table, and both
the loop thread and `stop` take entries from it under that same lock, so a completion and a stop can never
both deliver — and a `Join.resolveFirst` would absorb the second writer anyway. `stop` marks the table
stopped and fails everything parked *before* it asks the shim to stop, so an operation submitted afterwards is
refused at registration instead of parking until the process ends.

**The `hooks` registry is not on this path.** `Runtime.Hooks` counts registrations on `Std.Async` leaves, which
is what a driver reads as "in flight". A socket operation here registers no leaf: it parks on a cell the loop
thread resolves. `Runtime.pending` therefore does not count a parked read any more, which is why the callers'
`hooks` parameter is carried but not read — the accept loops and `Http.lean` pass it, and their signatures are
the callers'.
-/

namespace LeanIn.Runtime

/-- Begin one read on connection `idx`, held to at most `size` bytes. Returns 1 when the read was submitted and 0
when the loop is gone or its submission queue is full, in which case no completion will come. -/
@[extern "np_uv_read"] opaque npUvRead (idx : UInt32) (size : UInt64) : IO UInt32

/-- Write one buffer on connection `idx`, copying it into memory the write request owns. 1 submitted, 0 refused.
-/
@[extern "np_uv_write"] opaque npUvWrite (idx : UInt32) (bytes : ByteArray) : IO UInt32

/-- Write every buffer of `chunks` on connection `idx` as **one** write, in order: the shim copies them into one
block so the peer reads one segment. 1 submitted, 0 refused. -/
@[extern "np_uv_writev"] opaque npUvWritev (idx : UInt32) (chunks : Array ByteArray) : IO UInt32

/-- Shut down connection `idx`'s write side, then close its handle on that completion. 1 submitted, 0 refused. -/
@[extern "np_uv_shutdown"] opaque npUvShutdown (idx : UInt32) : IO UInt32

/-- Close connection `idx`'s handle. 1 submitted, 0 refused. -/
@[extern "np_uv_close"] opaque npUvClose (idx : UInt32) : IO UInt32

/-- Create the shim's loop, bind `127.0.0.1:port` and listen; returns the port actually bound, or 0 on failure.
The backlog is the shim's own (`511`, libuv's listen argument); the caller's backlog does not reach it. -/
@[extern "np_uv_start"] opaque npUvStart (port : UInt32) : IO UInt32

/-- Apply the queued submissions, then run one loop iteration, arming the wheel timer to wake after
`timeoutMs` so a deadline ends the park exactly as a socket or a submission does; `0` arms no timer, which is
the listener's shape. Returns 1 while the loop has anything left to do and 0 once it has been stopped and
drained — the loop thread's exit condition. -/
@[extern "np_uv_run_once_timeout"] opaque npUvRunOnceTimeout (timeoutMs : UInt32) : IO UInt32

/-- End the poll the loop is parked in so it re-reads the wheel: a timer scheduled with a deadline earlier than
the current park is picked up at once rather than when the old park would have ended. -/
@[extern "np_uv_wheel_wake"] opaque npUvWheelWake : IO Unit

/-- Drain the shim's event queue: `(kind, conn, arg)` triples, flat in one array. -/
@[extern "np_uv_events"] opaque npUvEvents : IO (Array UInt64)

/-- The bytes accumulated on connection `idx`, clearing them. The loop thread's alone: it is called where a
completion's bytes are still that connection's, before the next read on it can start. -/
@[extern "np_uv_take"] opaque npUvTake (idx : UInt32) : IO ByteArray

/-- Ask the loop to stop and drain. Callable from any thread; the loop thread does the closing. -/
@[extern "np_uv_stop"] opaque npUvStop : IO Unit

/-- The libuv name of an error code — `ECONNRESET`, `ECANCELED` — for a failure a caller can read. -/
@[extern "np_uv_err_name"] opaque npUvErrName (code : UInt32) : IO String

/-- Which operation parked on the loop. Used to match an event to the operation that asked for it: one
connection's read completion must never resolve that connection's write. -/
private inductive Op where
  | accept
  | read
  | write
  | shutdown
  deriving DecidableEq, BEq

/-- What the loop delivers to a parked operation. -/
private inductive Result where
  /-- A connection libuv accepted, by its index. -/
  | accepted (idx : UInt32)
  /-- A read's outcome: the bytes it returned, or `none` for end of stream. A *failed* read is delivered as an
  `IO.Error` instead, because a broken socket is not a value this layer has an encoding for. -/
  | read (data : Option ByteArray)
  /-- A write or a shutdown completed. -/
  | done

/-- One operation parked for the loop to complete: the connection it is on, what it is, the cell its result
lands in, and the route the loop thread delivers on — the submitting step's own shared route. -/
private structure Parked where
  conn : UInt32
  op   : Op
  cell : Task.Join (Except IO.Error Result)
  push : Task.Item → BaseIO Unit

/-- The loop's table: the operations parked for it, and the connections it accepted with no accept parked to
receive them. One lock, because the loop thread and the carriers both touch it — and the `stopped` flag lives
here rather than in a second `IO.Ref` so that the check a registration makes and the sweep a stop makes cannot
happen under two different locks. -/
private structure Table where
  parked  : List Parked := []
  arrived : List UInt32 := []
  stopped : Bool := false

/-- The oldest entry matching `p`, and the table without it. -/
private def Table.takeWhere (t : Table) (p : Parked → Bool) : Option Parked × Table :=
  let rec go : List Parked → List Parked → Option Parked × List Parked
    | [], acc => (none, acc.reverse)
    | x :: xs, acc => if p x then (some x, acc.reverse ++ xs) else go xs (x :: acc)
  let (found, rest) := go t.parked []
  (found, { t with parked := rest })

/-- A listener bound by the shim in this file: the address libuv bound it to, and the loop its connections
belong to. -/
structure Listener where
  private mk ::
  /-- The address bound. -/
  private addr : Std.Net.SocketAddress
  /-- The loop this listener's connections belong to. -/
  private loop : Std.Mutex Table

/-- A connection from this file's listener. -/
structure Conn where
  private mk ::
  /-- The shim's index for it, which is what every operation names. -/
  private idx : UInt32
  /-- The loop that owns it. An operation on a connection whose loop has been stopped is refused rather than
  parked: a retired listener's connection is a caller's error, and a hang would report it as a wait. -/
  private loop : Std.Mutex Table

/-- The loop thread and the table it delivers through, when a loop is running. -/
private structure Running where
  table : Std.Mutex Table
  thread : _root_.Task (Except IO.Error Unit)

/-- The running loop, if any: `startListener` replaces it, and `stopLoop` retires it. -/
private initialize loopRef : IO.Ref (Option Running) ← IO.mkRef none

/-- A timer the loop thread fires when it comes due: a monotone-nanosecond deadline, the token a winning read
sets to disarm the loser, and the fire — the parked waiter's own continuation, enqueued on the shared route so
it runs on a carrier rather than here. -/
private structure WheelTimer where
  deadline : Nat
  cancel   : Task.Cancel
  fire     : IO Unit

/-- The scheduling hand-off: timers carriers asked for (`liveSchedule`) and the loop thread has not yet taken
into the wheel it owns. The wheel itself is loop-thread-local — appended to and scanned by that one thread with
no lock — so a busy run does not pay a shared lock on every loop iteration; carriers touch only this queue,
which is taken in one pointer swap. -/
private initialize timerPending : Std.Mutex (Array WheelTimer) ← Std.Mutex.new #[]

namespace Io

/-- The signed reading of an event argument. libuv reports a failure as the negated error code, and the shim
carries that through a `UInt64`, so this is where the sign comes back. -/
private def signed (arg : UInt64) : Int :=
  let n := arg.toNat
  if n ≥ 2 ^ 63 then (n : Int) - 2 ^ 64 else (n : Int)

/-- The failure a libuv status names, spelled the way libuv spells it. -/
private def libuvError (what : String) (status : Int) : IO IO.Error := do
  let name ← npUvErrName status.natAbs.toUInt32
  return .userError s!"{what}: {name} ({status})"

/-- **Park an operation for the loop to complete**, or refuse it because the loop has been stopped. The refusal
is what keeps a retired listener's operation from parking until the process ends. -/
private def register (loop : Std.Mutex Table) (conn : UInt32) (op : Op)
    (cell : Task.Join (Except IO.Error Result)) (push : Task.Item → BaseIO Unit) :
    IO (Except IO.Error Unit) :=
  loop.atomically do
    let t : Table ← get
    if t.stopped then return .error (.userError "Io: the libuv loop has been stopped")
    let entry : Parked := { conn := conn, op := op, cell := cell, push := push }
    set { t with parked := t.parked ++ [entry] }
    return .ok ()

/-- Drop the entry a refused submission left behind, so a later event cannot resolve a cell nothing owns. -/
private def withdraw (loop : Std.Mutex Table) (conn : UInt32) (op : Op) : IO Unit :=
  loop.atomically do
    let (_, t') := (← get).takeWhere (fun p => p.op == op && p.conn == conn)
    set t'

/-- Hand an accepted connection to the oldest parked accept, or hold it until one registers. -/
private def arrive (loop : Std.Mutex Table) (idx : UInt32) : IO Unit := do
  let taken? ← loop.atomically do
    let (found, t') := (← get).takeWhere (fun p => p.op == .accept)
    set (if found.isSome then t' else { t' with arrived := t'.arrived ++ [idx] })
    return found
  match taken? with
  | some p => Task.Join.resolveFirst p.cell p.push (.ok (.accepted idx))
  | none   => pure ()

/-- Fail the oldest parked accept: there is no free connection slot for the connection that arrived. -/
private def noSlot (loop : Std.Mutex Table) : IO Unit := do
  let taken? ← loop.atomically do
    let (found, t') := (← get).takeWhere (fun p => p.op == .accept)
    set t'
    return found
  match taken? with
  | some p =>
    Task.Join.resolveFirst p.cell p.push
      (.error (.userError "Io: no free connection slot (the shim's slot table is full)"))
  | none => pure ()

/-- **Register an accept**, taking a connection the loop has already accepted if there is one. Three outcomes:
a connection to hand back in this step (`some` of an `ok` index), a parked operation (`ok none`), or a refusal
because the loop has been stopped. -/
private def claim (l : Listener) (cell : Task.Join (Except IO.Error Result))
    (push : Task.Item → BaseIO Unit) : IO (Except IO.Error (Option UInt32)) :=
  l.loop.atomically do
    let t : Table ← get
    if t.stopped then return .error (.userError "Io: the libuv loop has been stopped")
    match t.arrived with
    | idx :: rest => set { t with arrived := rest }; return .ok (some idx)
    | [] =>
      let entry : Parked := { conn := 0, op := .accept, cell := cell, push := push }
      set { t with parked := t.parked ++ [entry] }
      return .ok none

/-- **A read completed.** The bytes are taken here, on the loop thread, so they are still this connection's; a
failed read closes the connection, because a socket that reported one is not coming back and its slot must. -/
private def readDone (loop : Std.Mutex Table) (idx : UInt32) (n : Int) : IO Unit := do
  let taken? ← loop.atomically do
    let (found, t') := (← get).takeWhere (fun p => p.op == .read && p.conn == idx)
    set t'
    return found
  if n < 0 then
    let e ← libuvError "a socket read failed" n
    match taken? with
    | some p => Task.Join.resolveFirst p.cell p.push (.error e)
    | none   => pure ()
    if (← npUvClose idx) == 0 then
      throw (IO.userError "Io: the shim refused to close a read-broken connection")
  else
    let bytes ← npUvTake idx
    match taken? with
    | some p =>
      Task.Join.resolveFirst p.cell p.push (.ok (.read (if n == 0 then none else some bytes)))
    | none => pure ()

/-- **A write or a shutdown completed.** A failed write closes the connection for the same reason a failed read
does; a failed shutdown does not, because the shim closes the handle on a shutdown's completion either way. -/
private def opDone (loop : Std.Mutex Table) (idx : UInt32) (status : Int) (op : Op) : IO Unit := do
  let taken? ← loop.atomically do
    let (found, t') := (← get).takeWhere (fun p => p.op == op && p.conn == idx)
    set t'
    return found
  if status == 0 then
    match taken? with
    | some p => Task.Join.resolveFirst p.cell p.push (.ok .done)
    | none   => pure ()
  else
    let e ← libuvError
      (if op == .write then "a socket write failed" else "shutting a socket's write side down failed") status
    match taken? with
    | some p => Task.Join.resolveFirst p.cell p.push (.error e)
    | none   => pure ()
    if op == .write then
      unless (← npUvClose idx) == 1 do
        throw (IO.userError "Io: the shim refused to close a write-broken connection")

/-- **Deliver one batch of shim events**, in the order the shim recorded them. An unrecognised kind, or an
overflowed queue, is a defect in this file's contract with `c/netuv.c` rather than a connection's behaviour, so
it throws and the loop thread dies loudly instead of continuing with a queue it cannot read. -/
private def dispatch (loop : Std.Mutex Table) (evs : Array UInt64) : IO Unit := do
  let mut i := 0
  while i + 2 < evs.size do
    let kind := evs[i]!
    let conn := evs[i + 1]!
    let arg  := evs[i + 2]!
    i := i + 3
    match kind.toNat with
    | 1 => arrive loop conn.toUInt32                                    -- accepted
    | 2 => readDone loop conn.toUInt32 (signed arg)                     -- read completed
    | 3 => opDone loop conn.toUInt32 (signed arg) .write                -- write completed
    | 4 => opDone loop conn.toUInt32 (signed arg) .shutdown             -- shutdown completed
    | 5 => throw (IO.userError "Io: the shim's event queue overflowed; the loop was not being drained")
    | 6 => noSlot loop                                                  -- no free connection slot
    | k => throw (IO.userError s!"Io: unknown libuv event kind {k}")

/-- Pop every wheel entry whose deadline has passed, earliest first, leaving only future timers. The map is
keyed on the deadline, so this is one `minEntry?`/`erase` per *due* deadline — `O(k log n)` for `k` due, and a
single `O(log n)` peek when nothing is due — never a scan of the timers still waiting. -/
private partial def popDue (wheel : Std.TreeMap Nat (Array WheelTimer)) (now : Nat)
    (acc : Array WheelTimer) : Std.TreeMap Nat (Array WheelTimer) × Array WheelTimer :=
  match wheel.minEntry? with
  | some (d, ts) =>
    if d ≤ now then popDue (wheel.erase d) now (acc ++ ts)
    else (wheel, acc)
  | none => (wheel, acc)

/-- The loop thread: take the timers carriers scheduled into the wheel this thread owns, fire every one that
has come due, re-arm the park timeout to the earliest remaining deadline, run one shim iteration, and drain
what it recorded. The wheel is this thread's alone, so a timer is serviced by the same iteration that services
socket completions — there is no deadline thread — and a busy run pays no shared lock to read it.

The wheel is a `TreeMap` ordered on the deadline, not a flat list. A run's `withTimeout` losers are never
cancelled, so they accumulate — thousands of them under load — and the operation this thread needs each
iteration is the *earliest* deadline (for the park timeout) plus the timers *already due*, both of which an
ordered map answers in `O(log n)`. A flat list paid `O(n)` for the same two readings on every iteration, which
is what put the latency and throughput regression in: the work grew with the count of *waiting* timers whether
or not any was due.

The exit check runs under the queue's lock so it is serialised against `liveSchedule`: the shim's `2` means the
loop was stopped and drained, so the thread exits even with timers outstanding (a stopping program abandons
them); a `0` means nothing is armed, so a timer-only loop exits only once neither its wheel nor the queue holds
a timer — otherwise it would strand the deadline it was started for. A `liveSchedule` that lands as the loop
hands itself back (`loopRef` to `none`) starts a fresh one. -/
private partial def loopIterate (loop : Std.Mutex Table) (wheel : Std.TreeMap Nat (Array WheelTimer)) : IO Unit := do
  let now ← IO.monoNanosNow
  let fresh ← timerPending.atomically do
    let ps ← get
    set (#[] : Array WheelTimer)
    return ps
  let wheel := fresh.foldl (fun w t =>
    match w.get? t.deadline with
    | some ts => w.insert t.deadline (ts.push t)
    | none    => w.insert t.deadline #[t]) wheel
  let (wheel, due) := popDue wheel now #[]
  for t in due do
    unless ← Task.Cancel.isSet t.cancel do
      t.fire
  let nextDue := wheel.minKey?
  let timeoutMs : UInt32 := match nextDue with
    | some d => if d > now then (max 1 ((d - now) / 1000000)).toUInt32 else 1
    | none => 0
  let active ← npUvRunOnceTimeout timeoutMs
  dispatch loop (← npUvEvents)
  let again ← timerPending.atomically do
    if active == 2 || (active == 0 && wheel.isEmpty && (← get).isEmpty) then
      loopRef.set none
      return false
    else
      return true
  if again then loopIterate loop wheel else pure ()

/-- **Schedule a fire at a monotone-nanosecond deadline.** Callable from any carrier: the entry is appended to
the hand-off queue and the loop is woken so a deadline earlier than its current park is picked up at once. The
loop thread is started here when this timer is the first thing to need one — a program that binds no listener
still has its timers serviced — and the check-and-start runs under the queue's lock so two carriers cannot
start two loop threads on the one libuv loop. The wake is load-bearing, not an optimisation: a timer scheduled
while the loop is parked with nothing armed — a standalone sleep against an idle listener, SC11's shape —
strands without it, so it is sent unconditionally rather than gated on a park state that could be read stale.
`startListener` and `liveSchedule` are not serialised against each other: a process binds its listeners before
it schedules timers, or schedules no timers — every scenario's shape. -/
def liveSchedule (deadline : Nat) (cancel : Task.Cancel) (fire : IO Unit) : IO Unit := do
  timerPending.atomically do
    modify (·.push { deadline, cancel, fire })
    match ← loopRef.get with
    | some _ => pure ()
    | none   => do
        let table ← Std.Mutex.new ({} : Table)
        let thread ← IO.asTask (loopIterate table Std.TreeMap.empty) _root_.Task.Priority.dedicated
        loopRef.set (some { table, thread })
  npUvWheelWake

/-- **Stop the running loop**: fail everything parked, ask the shim to stop, and wait for the loop thread to
drain. The order matters — the table is marked stopped *before* the shim is asked — so an operation that
registers after this point is refused at registration rather than parked on a loop that is going away.

Two callers, and the second is why this is public. `startListener` stops the previous loop before binding its own,
which is where a retired listener's operations fail loudly instead of parking. And a **program** stops the loop
before it returns: Lean's task manager waits for every dedicated task when it shuts the runtime down
(`~task_manager` waits on `m_num_dedicated_workers`), and the loop thread is a dedicated task that would
otherwise be parked in `uv_run` for as long as the listener exists — so a program that bound a listener and does
not stop it here finishes its work and then hangs in the runtime's own shutdown. Nothing else in the runtime can
close that: there is no exit hook to register, and a process-level signal keeps its default disposition because
Lean's own signal machinery owns those (see `c/netuv.c`'s header). -/
def stop : IO Unit := do
  match ← loopRef.get with
  | none => pure ()
  | some r => do
      let parked ← r.table.atomically do
        let t ← get
        let ps := t.parked
        set { t with parked := [], arrived := [], stopped := true }
        return ps
      for p in parked do
        Task.Join.resolveFirst p.cell p.push
          (.error (.userError "Io: the libuv loop was stopped while an operation was parked"))
      -- Drop timers carriers scheduled but the loop has not yet taken, before the shim is asked to stop: the
      -- loop thread is about to abandon the wheel it owns (the shim's `2` retires it), so a timer left queued
      -- here would otherwise sit unclaimed. Their waiters are a stopping program's own; nothing resumes them.
      timerPending.atomically (set (#[] : Array WheelTimer))
      npUvStop
      match ← IO.wait r.thread with
      | .ok _    => pure ()
      | .error e => throw e
      loopRef.set none

/-- **Bind a listener and start its loop.** The port must be an IPv4 loopback one: the shim binds `127.0.0.1`
itself, so a different address is refused loudly rather than silently binding loopback. `backlog` is carried for
the caller's signature and does not reach the shim, whose listen backlog is libuv's own argument.

A running loop is stopped first (`stop`), and every published operation on its listener and its connections
then fails rather than hanging. -/
def startListener (addr : Std.Net.SocketAddress) (_backlog : UInt32) : IO Listener := do
  let port ← match addr with
    | .v4 a =>
      unless a.addr.octets == #v[127, 0, 0, 1] do
        throw (IO.userError "Io.startListener: the shim binds 127.0.0.1 and no other address")
      pure a.port
    | .v6 _ =>
      throw (IO.userError "Io.startListener: the shim binds the IPv4 loopback address only")
  stop
  let bound ← npUvStart port.toUInt32
  if bound == 0 then
    throw (IO.userError s!"Io.startListener: could not bind 127.0.0.1:{port}")
  let table ← Std.Mutex.new ({} : Table)
  let thread ← IO.asTask (loopIterate table Std.TreeMap.empty) _root_.Task.Priority.dedicated
  loopRef.set (some { table := table, thread := thread })
  return ⟨.v4 ⟨⟨#v[127, 0, 0, 1]⟩, bound.toUInt16⟩, table⟩

/-- The address this listener is bound to — the one libuv reported at bind time, so an ephemeral port is the one
the OS chose rather than the zero that asked for it. -/
def sockName (l : Listener) : IO Std.Net.SocketAddress := return l.addr

/-- **Accept, awaited as one of ours.** A connection libuv has already accepted but that no accept has claimed
is returned in this step; otherwise the operation parks on a cell the loop thread resolves when a connection
arrives. An accept that the loop can no longer complete is a failure rather than a wait. -/
def accept (l : Listener) : Task.EAsync IO.Error Conn :=
  ⟨fun k ctx => do
    let cell ← (Task.Join.new : IO (Task.Join (Except IO.Error Result)))
    match ← claim l cell ctx.resumeShared with
    | .error e      => k (.error e) ctx
    | .ok (some idx) => k (.ok ⟨idx, l.loop⟩) ctx
    | .ok none =>
      (Task.Async.await (show Task.Task (Except IO.Error Result) from ⟨cell, ctx.cancel⟩)).step
        (fun r ctx' => k (match r with
          | .ok (.accepted idx) => .ok ⟨idx, l.loop⟩
          | .ok _               => .error (.userError "Io.accept: the loop delivered a mismatched completion")
          | .error e            => .error e) ctx') ctx⟩

/-- **Accept without waiting**: a connection the loop has already accepted and no accept has claimed, or `none`.
This is the non-blocking attempt `Runtime.serveUntilStopped` polls with, so its cost is the table's lock and not
a scheduling round; a connection still in the kernel's backlog is `none` until the loop reports it, which is the
same interval the polling driver already lives with. -/
def tryAccept (l : Listener) : IO (Option Conn) :=
  l.loop.atomically do
    let t ← get
    match t.arrived with
    | idx :: rest => set { t with arrived := rest }; return (some ⟨idx, l.loop⟩)
    | []          => return none

/-- **Receive up to `size` bytes**, `none` at end of stream. The read is submitted and the operation parks; the
loop thread's own `uv_read_stop` after each read is what makes this one read per call rather than a stream. -/
def recv (c : Conn) (size : UInt64) : Task.EAsync IO.Error (Option ByteArray) :=
  ⟨fun k ctx => do
    let cell ← (Task.Join.new : IO (Task.Join (Except IO.Error Result)))
    let push := ctx.resumeShared
    match ← register c.loop c.idx .read cell push with
    | .error e => k (.error e) ctx
    | .ok () =>
      if (← npUvRead c.idx size) == 0 then
        withdraw c.loop c.idx .read
        k (.error (.userError "Io.Conn.recv: the loop refused a read submission")) ctx
      else
        (Task.Async.await (show Task.Task (Except IO.Error Result) from ⟨cell, ctx.cancel⟩)).step
          (fun r ctx' => k (match r with
            | .ok (.read d) => .ok d
            | .ok _         => .error (.userError "Io.Conn.recv: the loop delivered a mismatched completion")
            | .error e      => .error e) ctx') ctx⟩

/-- **Send one buffer**, awaiting its completion. The bytes are copied into memory the write request owns at the
submission, so the caller's buffer can go away before the write finishes. -/
def send (c : Conn) (data : ByteArray) : Task.EAsync IO.Error Unit :=
  ⟨fun k ctx => do
    let cell ← (Task.Join.new : IO (Task.Join (Except IO.Error Result)))
    let push := ctx.resumeShared
    match ← register c.loop c.idx .write cell push with
    | .error e => k (.error e) ctx
    | .ok () =>
      if (← npUvWrite c.idx data) == 0 then
        withdraw c.loop c.idx .write
        k (.error (.userError "Io.Conn.send: the loop refused a write submission")) ctx
      else
        (Task.Async.await (show Task.Task (Except IO.Error Result) from ⟨cell, ctx.cancel⟩)).step
          (fun r ctx' => k (match r with
            | .ok .done => .ok ()
            | .ok _     => .error (.userError "Io.Conn.send: the loop delivered a mismatched completion")
            | .error e  => .error e) ctx') ctx⟩

/-- **Send several buffers as one write.** One submission carrying every buffer, in order, so the peer reads one
segment: the buffers are written back to back inside one `uv_write`, which is both what the operation means and
what keeps Nagle out of it — two separate writes on a connection with unacknowledged data are two segments, and
the second waits on the peer's delayed ACK. -/
def sendAll (c : Conn) (chunks : Array ByteArray) : Task.EAsync IO.Error Unit :=
  ⟨fun k ctx => do
    let cell ← (Task.Join.new : IO (Task.Join (Except IO.Error Result)))
    let push := ctx.resumeShared
    match ← register c.loop c.idx .write cell push with
    | .error e => k (.error e) ctx
    | .ok () =>
      if (← npUvWritev c.idx chunks) == 0 then
        withdraw c.loop c.idx .write
        k (.error (.userError "Io.Conn.sendAll: the loop refused a write submission")) ctx
      else
        (Task.Async.await (show Task.Task (Except IO.Error Result) from ⟨cell, ctx.cancel⟩)).step
          (fun r ctx' => k (match r with
            | .ok .done => .ok ()
            | .ok _     => .error (.userError "Io.Conn.sendAll: the loop delivered a mismatched completion")
            | .error e  => .error e) ctx') ctx⟩

/-- **Shut the write side down.** The shim closes the connection's handle on that completion, so the peer reads
the end of stream before the socket goes, and this returns once the shutdown did. -/
def shutdown (c : Conn) : Task.EAsync IO.Error Unit :=
  ⟨fun k ctx => do
    let cell ← (Task.Join.new : IO (Task.Join (Except IO.Error Result)))
    let push := ctx.resumeShared
    match ← register c.loop c.idx .shutdown cell push with
    | .error e => k (.error e) ctx
    | .ok () =>
      if (← npUvShutdown c.idx) == 0 then
        withdraw c.loop c.idx .shutdown
        k (.error (.userError "Io.Conn.shutdown: the loop refused a shutdown submission")) ctx
      else
        (Task.Async.await (show Task.Task (Except IO.Error Result) from ⟨cell, ctx.cancel⟩)).step
          (fun r ctx' => k (match r with
            | .ok .done => .ok ()
            | .ok _     => .error (.userError "Io.Conn.shutdown: the loop delivered a mismatched completion")
            | .error e  => .error e) ctx') ctx⟩

/-- **Close the connection's handle**: the socket goes, the peer's read ends at the FIN, and the shim's slot
comes back. A submission rather than an awaited operation — there is no completion to deliver, and a caller that
closes a connection has nothing left to wait for on it.

Idempotent, and that is why it is safe to close a connection whose write side was already shut down: the shim
checks `uv_is_closing`, so a second close is a no-op that reports success. It fails only when the shim cannot take
the submission at all — a loop that has been stopped, or a full submission queue — where there is nothing the
caller can do but hear it. -/
def close (c : Conn) : IO Unit := do
  if (← npUvClose c.idx) == 0 then
    throw (IO.userError "Io.close: the shim refused to close the connection")
