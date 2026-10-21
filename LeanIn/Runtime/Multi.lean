module

public import LeanIn.Runtime.Basic
public import LeanIn.Runtime.Net

public section
/-!
# Serving on several carriers

The listener's bind starts the shim's pump thread, which owns the loop. `runCarriersWait` starts `p` executor
carriers for workers `0 … p-1`, pushes the program's root on the shared inject, and waits for completion. Every
accepted connection is spawned the same way, so any free carrier takes it.

**Affinity:** a connection stays on the carrier that took its first step, because a step's child follows the
worker that ran the parent. The accept chain stays on the carrier that ran it. The pool is widened; a single
connection's state machine is not.

`waitFinished` polls the completion flag rather than parking on the carriers' condition variable: a push uses
`notifyOne`, and a caller competing for that wake can leave the intended carrier asleep.
-/

namespace LeanIn.Runtime

/-- Spawn a computation on the shared inject, so a carrier other than the spawning one may take it. The
completion also takes the shared route: the awaiter may be on another carrier (or parked on a handle), and a
local completion would strand it there. -/
def spawnShared (e : Executor cap) (a : Task.Async α) : IO (Task.Task α) := do
  let cell ← Task.Join.new
  let cancel ← Task.Cancel.new
  let it := Task.Item.ofIndexed (some cancel)
    (fired cancel e a (fun v ctx => Task.Join.resolve cell ctx.resumeShared v))
  e.pushInject (Task.Item.sendable it)
  return ⟨cell, cancel⟩

/-- The accept loop with shared dispatch: an accepted connection is served through `Conn.serveBody` and
spawned on the shared inject. The loop itself stays on the carrier that ran its first step. -/
partial def serveForeverShared (hooks : Hooks) (e : Sched.Executor Task.Item cap) (l : Listener)
    (body : Conn → Task.EAsync IO.Error Unit) : Task.EAsync IO.Error Unit := do
  let c ← Listener.accept l hooks
  let _ ← monadLift (spawnShared e (Conn.serveBody body c))
  serveForeverShared hooks e l body

/-- Serve exactly `n` connections with shared dispatch, then await all of them. -/
def serveNJoinShared (hooks : Hooks) (e : Sched.Executor Task.Item cap) (l : Listener) (n : Nat)
    (body : Conn → Task.EAsync IO.Error Unit) : Task.EAsync IO.Error Unit := do
  let reg : Task.Registry (Except IO.Error Unit) ← monadLift (Task.Registry.new (α := Except IO.Error Unit))
  for _ in List.range n do
    let c ← Listener.accept l hooks
    let h ← monadLift (spawnShared e (Conn.serveBody body c))
    monadLift (Task.Registry.add reg h)
  Task.EAsync.ofAsync (Task.Registry.joinAll reg)

/-- **Run `a` on `p` carriers and wait for it.** The caller does not park on the carriers' condition
variable: `Executor.waitFinished` polls, so a `notifyOne` meant for a worker cannot be taken by the caller.
The carriers are stopped and joined before the result is returned. -/
def runCarriersWait (e : Executor cap) (p : Nat) (a : Task.Async α) : IO (Carriers cap × α) := do
  if p == 0 then throw (.userError "Runtime.runCarriersWait: at least one carrier is required")
  let c ← startCarriersFrom e 0 p
  let done ← Std.Mutex.new (none : Option α)
  e.clearFinished
  let cancel ← Task.Cancel.new
  let finish : α → Task.Ctx → IO Unit := fun v _ => do
    done.atomically do set (some v)
    e.noteFinished
  let it := Task.Item.ofIndexed (some cancel) (fired cancel e a finish)
  e.pushInject (Task.Item.sendable it)
  try
    e.waitFinished
  finally
    c.stop
    c.join
  match ← done.atomically do return (← get) with
  | some v => return (c, v)
  | none => throw (.userError "runCarriersWait: no result")

end LeanIn.Runtime
end
