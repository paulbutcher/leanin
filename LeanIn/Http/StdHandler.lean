module

public import Std.Http.Server
public import LeanIn.Http.Server
public import LeanIn.Http.H1

public section
/-!
# A `Std.Http`-shaped handler on the streaming driver

A `StdHandler` takes a `Std.Http.Request` and returns a `Std.Http.Response`, so code written against
`Std.Http.Server`'s request and response types runs on LeanIn with only its monad and body types changed. The
request body is LeanIn's `BodyReader` and the response body a `ResponseBody`; the monad is `VM`.

This is a **conversion at dispatch**, not a second driver: `StdHandler.toStream` builds a `StreamHandler`, and
`serveConnStd` serves it through `serveConnStream`. The H1 machine and the native path are unchanged; the stock
header map and the parsed target are built only for a handler that asks for them by being a `StdHandler`.
-/

namespace LeanIn.Http

open LeanIn.Runtime

/-- A response body as a `StdHandler` returns it: the whole body, or a writer that is handed a chunk sink and
runs once the head is sent. A streamed body with a known length declares it; otherwise it is chunked on
HTTP/1.1 and close-delimited on HTTP/1.0. -/
inductive ResponseBody where
  | bytes (data : ByteArray)
  | stream (length? : Option Nat) (write : (ByteArray → VM Unit) → VM Unit)

instance : Inhabited ResponseBody := ⟨.bytes .empty⟩

/-- A request handler over `Std.Http`'s request and response types, with `Std.Http.Server.Handler`'s two hooks.

`onFailure` is a **notification**, as in `Std`: it is told of an error the handler raises, of a request head
`Std` rejects, and of a transport failure (an abort), and the failure then takes its usual course — a raise
becomes the driver's `500` when no response has started, an abort closes the connection. An error `onFailure`
raises itself is discarded.

`onContinue` is asked when an HTTP/1.1 request carries `Expect: 100-continue`. `true` sends `100 Continue` and
runs the handler; `false` (or a raise) answers `417 Expectation Failed` without running it, and the connection
closes unless the request had no body to wait for. -/
structure StdHandler where
  onRequest : Std.Http.Request Server.BodyReader → VM (Std.Http.Response ResponseBody)
  onFailure : IO.Error → VM Unit := fun _ => pure ()
  onContinue : Std.Http.Request.Head → VM Bool := fun _ => pure true

namespace StdHandler

/-- H1's method to the stock method. An unclassified token goes through `Std.Http.Method.ofString?`. -/
def methodToStock (h : H1.Head) : Except IO.Error Std.Http.Method :=
  match h.method with
  | .get => .ok .get
  | .head => .ok .head
  | .post => .ok .post
  | .put => .ok .put
  | .delete => .ok .delete
  | .options => .ok .options
  | .patch => .ok .patch
  | .trace => .ok .trace
  | .connect => .ok .connect
  | .other =>
      match Std.Http.Method.ofString? h.methodTokenString with
      | some m => .ok m
      | none => .error (.userError s!"Http.StdHandler: unknown method {h.methodTokenString}")

def versionToStock (v : H1.Version) : Std.Http.Version :=
  match v with | .v10 => .v10 | .v11 => .v11

/-- The request head, with the header slices resolved to stock names and values. -/
def headToStock (h : H1.Head) : Except IO.Error Std.Http.Request.Head := do
  let method ← methodToStock h
  let uri ← match Std.Http.RequestTarget.parse? h.targetString with
    | some u => pure u
    | none => throw (.userError s!"Http.StdHandler: invalid request target {h.targetString}")
  let mut headers := Std.Http.Headers.empty
  for (n, v) in h.headers do
    let name ← match H1.Slice.toString? h.buf n with
      | some s => pure s
      | none => throw (.userError "Http.StdHandler: a header name is not UTF-8")
    let value ← match H1.Slice.toString? h.buf v with
      | some s => pure s
      | none => throw (.userError "Http.StdHandler: a header value is not UTF-8")
    let some stockName := Std.Http.Header.Name.ofString? name
      | throw (.userError s!"Http.StdHandler: invalid header name {name}")
    let some stockValue := Std.Http.Header.Value.ofString? value
      | throw (.userError s!"Http.StdHandler: invalid header value {value}")
    headers := headers.insert stockName stockValue
  return { method, version := versionToStock h.version, uri, headers }

/-- The response head LeanIn's writer sends for a stock response head. -/
def responseHead (line : Std.Http.Response.Head) : H1.ResponseHead :=
  { status := line.status.toCode.toNat
    reason := line.status.reasonPhrase
    headers := line.headers.toArray.map (fun (n, v) => (n.value, v.value)) }

/-- Whether a response head already carries `name` (ASCII case-insensitive). -/
def hasHeader (rh : H1.ResponseHead) (name : String) : Bool :=
  rh.headers.any (fun (n, _) => n.toLower == name)

private def pad2 (n : Nat) : String := if n < 10 then s!"0{n}" else toString n

/-- Seconds since the Unix epoch as an IMF-fixdate (RFC 9110 §5.6.7), `Sun, 06 Nov 1994 08:49:37 GMT`. The
civil date is Hinnant's `civil_from_days`, so no time zone database is read. -/
def imfFixdate (secs : Int) : String :=
  let days := secs / 86400
  let rem := (secs % 86400).toNat
  let weekday := ((days + 4) % 7).toNat                     -- 1970-01-01 was a Thursday
  let z := days + 719468
  let era := (if z ≥ 0 then z else z - 146096) / 146097
  let doe := (z - era * 146097).toNat
  let yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp := (5 * doy + 2) / 153
  let day := doy - (153 * mp + 2) / 5 + 1
  let month := if mp < 10 then mp + 3 else mp - 9
  let year := yoe + era * 400 + (if month ≤ 2 then 1 else 0)
  let wd := #["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][weekday]!
  let mon := #["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][month - 1]!
  s!"{wd}, {pad2 day} {mon} {year} {pad2 (rem / 3600)}:{pad2 (rem % 3600 / 60)}:{pad2 (rem % 60)} GMT"

/-- The last `Date` value formatted, keyed by its second, so a busy server formats once a second. Carriers share
it; two that miss in the same second each format and store the same value. -/
initialize dateCache : IO.Ref (Int × String) ← IO.mkRef (-1, "")

/-- The current `Date` header value. -/
def currentDate : IO String := do
  let secs := (← Std.Time.Timestamp.now).toSecondsSinceUnixEpoch.val
  let (at_, s) ← dateCache.get
  if at_ == secs then return s
  let s := imfFixdate secs
  dateCache.set (secs, s)
  return s

/-- Add a `Date` when `date` is set and the head has none. -/
def withDate (date : Bool) (rh : H1.ResponseHead) : VM H1.ResponseHead := do
  if date && !hasHeader rh "date" then
    let d ← (monadLift currentDate : VM String)
    return { rh with headers := rh.headers.push ("Date", d) }
  return rh

/-- Write a stock response through LeanIn's writer, adding a `Date` when `date` is set and the handler gave
none. -/
def writeResponse (w : Server.ResponseWriter) (r : Std.Http.Response ResponseBody) (date : Bool := true) :
    VM Unit := do
  let rh ← withDate date (responseHead r.line)
  match r.body with
  | .bytes data => Server.Stream.respond w rh data
  | .stream length? write =>
    let rh := match length? with
      | some n => if hasHeader rh "content-length" then rh
                  else { rh with headers := rh.headers.push ("Content-Length", toString n) }
      | none => rh
    w.start rh
    write w.write
    w.finish

/-- A response the layer answers itself, without the handler. The connection is closed (`Connection: close`, and
the unread body keeps the driver from reusing it) unless the body has already been read in full. -/
def refuse (reader : Server.BodyReader) (w : Server.ResponseWriter) (status : Nat) (reason : String)
    (date : Bool) : VM Unit := do
  let drained ← reader.drained
  let rh : H1.ResponseHead := { status, reason }
  let rh := if drained then rh else { rh with headers := rh.headers.push ("Connection", "close") }
  let rh ← withDate date rh
  Server.Stream.respond w rh .empty

/-- The `Extensions` a request starts with: the peer's address as `Std.Http.Server.RemoteAddr`, where
`Std.Http.Server` puts it. -/
def extensionsOf (reader : Server.BodyReader) : Std.Http.Extensions :=
  match reader.peer with
  | some addr => Std.Http.Extensions.empty.insert (Std.Http.Server.RemoteAddr.mk addr)
  | none => Std.Http.Extensions.empty

/-- Tell `onFailure` of a failure, discarding any error it raises itself. -/
def notify (h : StdHandler) (e : IO.Error) : VM Unit := do
  let _ ← VM.attempt (h.onFailure e)

/-- The `StreamHandler` that serves `h`. It needs the driver's `continuePolicy` to be `application`, which
`serveConnStd` sets, so that the `100 Continue` is this layer's to send or withhold. -/
def toStream (h : StdHandler) (date : Bool := true) : Server.StreamHandler := fun head reader w =>
  VM.tryAbort
    (try
      match headToStock head with
      | .error e =>
        h.notify e
        refuse reader w 400 "Bad Request" date
      | .ok line =>
        let proceed ← if head.version == .v11 && H1.expectsContinue head then do
            match ← VM.attempt (h.onContinue line) with
            | .ok true => w.sendContinue; pure true
            | _ => pure false
          else pure true
        if proceed then
          let response ← h.onRequest { line, body := reader, extensions := extensionsOf reader }
          writeResponse w response date
        else
          refuse reader w 417 "Expectation Failed" date
    catch e => do
      h.notify e
      throw e)
    (fun r => do
      h.notify r
      VM.abort r)

end StdHandler

/-- Serve a `StdHandler` on one connection, through the streaming driver. The continue decision is the
handler's `onContinue`, so `cfg.continuePolicy` is overridden with `application`. -/
def Server.serveConnStd (cfg : Server.Config) (c : Conn) (h : StdHandler) : Task.EAsync IO.Error Unit := do
  unless cfg.continuePolicy == .application do
    throw (.userError "Server.serveConnStd: Config.continuePolicy must be .application")
  Server.serveConnStream cfg c (h.toStream cfg.generateDate)

end LeanIn.Http
end
