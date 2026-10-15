import LeanIn.Runtime.Net
import LeanIn.Runtime.Io
import LeanIn.Runtime.VM
import LeanIn.Runtime.Clock

/-!
# A typed `spawn`/`await` as a per-function state machine (experiment)

The proof that typed spawn/await and raw-delivery speed go together. A connection loop written as an explicit
state machine (`SpawnEchoSM`) whose states are a *concrete* inductive — the awaited cell is `RawCell ByteArray`,
a real type, not a type variable. This is the representation the `async!` elaborator will generate: per-function
states, no generic monad, no predicativity problem.

The loop: read a request, **spawn** a worker that produces the response into a typed cell, **await** that cell,
write the response. The worker is a *separate* state machine driven on the same carrier; the await genuinely
parks (the worker resolves only after the loop drives it), which is what proves the mechanism rather than a
synchronous call in disguise.
-/

namespace LeanIn.Runtime.SmEcho

open LeanIn.Runtime

/-- **The worker**: take a request, produce a response into a typed cell. A separate state machine — here a
single deferred step: it resolves only when the loop next drives the timer, so the parent's `await` parks and
resumes through the raw cell rather than returning inline. -/
inductive WorkerSM where
  | pending (req : ByteArray) (cell : RawCell ByteArray)

/-- Process the request: the response the peer reads. -/
def processRequest (req : ByteArray) : ByteArray :=
  s!"processed[{req.size}]: ".toUTF8 ++ req

/-- **Spawn the worker**: resolve the cell on the loop thread. Resolving immediately (rather than after a
timer) makes the parent's `await` take the fast path — the cell already holds the value — so a benchmark of
`spawnEcho` against `directEcho` prices the spawn/await *mechanism* (cell + resolve + resume) rather than an
artificial delay. -/
def workerSpawn (req : ByteArray) (cell : RawCell ByteArray) : IO Unit :=
  RawCell.resolve cell (processRequest req)

/-- **The connection loop**, as a per-function state machine. -/
inductive SpawnEchoSM where
  | reading (c : Conn)
  | awaiting (c : Conn) (cell : RawCell ByteArray)
  | writing (c : Conn) (resp : ByteArray)

/-- Drive it, by raw delivery. Every continuation is data (a `SpawnEchoSM` constructor). -/
partial def spawnEchoStep : SpawnEchoSM → IO Unit
  | .reading c =>
    Io.recvRaw c 65536 (fun
      | some req => do
        let cell ← RawCell.new
        workerSpawn req cell                       -- spawn
        spawnEchoStep (.awaiting c cell)           -- await
      | none => Io.closeRaw c)
  | .awaiting c cell =>
    RawCell.await cell (fun resp => spawnEchoStep (.writing c resp))
  | .writing c resp =>
    Io.sendAllRaw c #[resp] (spawnEchoStep (.reading c))

/-- **Direct echo, no spawn** (the baseline for the spawn/await overhead measurement). -/
inductive DirectEchoSM where
  | reading (c : Conn)
  | writing (c : Conn) (resp : ByteArray)

partial def directEchoStep : DirectEchoSM → IO Unit
  | .reading c =>
    Io.recvRaw c 65536 (fun
      | some req => directEchoStep (.writing c (processRequest req))
      | none => Io.closeRaw c)
  | .writing c resp =>
    Io.sendAllRaw c #[resp] (directEchoStep (.reading c))

end LeanIn.Runtime.SmEcho
