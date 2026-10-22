# `Std.Http`-shaped handlers — behaviour checks

A `StdHandler` takes a `Std.Http.Request` and returns a `Std.Http.Response`, and is served through the streaming
driver by `Server.serveConnStd`. The checks here drive that at its public socket: a client speaks HTTP/1.1 to the
`stdEcho` executable on loopback and reads what comes back, and the executable's own handler prints a record for
each request it runs (`ran|`), each continue decision it makes (`continue|`) and each failure it is notified of
(`failure|`).

```sh
nix develop -c bash tests/std-handler-contract.sh SH1
```

Substitute `SH2`, `SH3` or `SH4`. The fixture is `tests/std-handler-contract.sh`. Each invocation builds
`stdEcho`, serves it on a port of its own (`STD_PORT`, default 8794), runs one scenario and stops it. Records are
the handler's own annotations: a scenario can see what the handler ran and was told, and nothing the driver does
that the handler is not shown.

A failure before the scenario's own assertion — the build, the server not listening, a malformed record, or an
absence detector whose affirmative control in the same run does not hold — is a setup error with exit 2. A
scenario assertion that does not hold exits 1. The socket timeouts bound a hang; none of them is a result.

These are trace tests: they can falsify the contract, and they cannot establish that it holds for requests they
do not send.

## SH1 — the handler sees a stock request head, its extensions and a `Date`

**Actor.** A client on loopback, and the `stdEcho` handler's `/info` route.

**Boundary.** The server's socket. The response body is the handler's own report of what it was handed.

**Given.** A fresh server.

**When.** The client sends `GET /info?q=1` with two `X-Multi` headers, `a` then `b`.

**Then.** The status is `200`. The body's `method` field is `GET` and its `target` field is `/info?q=1`, read
from `Request.Head.method` and `Request.Head.uri`. Its `x-multi` field is `a,b`: both values, in order, from
`Headers.getAll?`. Its `remote` field starts with `127.0.0.1:`, read from the `Std.Http.Server.RemoteAddr`
extension. The response carries a `Date` header in IMF-fixdate form, because the handler set none.

## SH2 — a refused `100-continue` answers `417` and does not run the handler

**Actor.** A client that sends `Expect: 100-continue` and waits, and the handler's `onContinue`, which refuses
`/refuse` and accepts everything else.

**Boundary.** The server's socket, and the `ran|` records.

**Given.** A fresh server. The absence detector is "a `ran|` record whose `target` field is exactly the given
target". Its affirmative control, in the same run: the client sends `POST /accept` with `Content-Length: 5` and
`Expect: 100-continue`, reads `100 Continue`, sends `hello`, reads `200` with body `hello`, and the detector finds
`target=/accept`.

**When.** The client sends `POST /refuse` with `Content-Length: 5` and `Expect: 100-continue`, and sends no body.

**Then.** The first response head is `417 Expectation Failed`. The server then closes the connection: the next
read is end of file. The detector finds no `ran|` record with `target=/refuse`.

## SH3 — `onFailure` is notified of a handler error and of a transport failure, once each

**Actor.** A client, and the handler's `onFailure`, which prints `failure|err=...`.

**Boundary.** The server's socket, and the `failure|` records.

**Given.** A fresh server. The detector counts `failure|` records.

**When.** In order:

1. The client sends `GET /throw`, whose handler raises `boom`.
1. The client sends a clean `GET /info`.
1. The client sends `POST /echo` with `Content-Length: 100` and five bytes of body, then closes the socket.
1. The client sends a clean `GET /info`.

**Then.** Step 1 answers `500`, and the count goes from 0 to 1 with a record whose `err` field is `boom`. That
record is also the detector's affirmative control. Step 2 answers `200` and the count stays at 1. After step 3
the count reaches 2, with one new record. After step 4 answers `200`, the count is still 2: the transport failure
was reported exactly once.

## SH4 — a head `Std` rejects answers `400` and does not run the handler

**Actor.** A client, and the conversion from LeanIn's parsed head to `Std.Http.Request.Head`.

**Boundary.** The server's socket, and the `ran|` records.

**Given.** A fresh server and SH2's detector. Its affirmative control, in the same run: `GET /info?case=good`
with `X-Bad: ab` answers `200`, and the detector finds `target=/info?case=good`.

**When.** The client sends `GET /info?case=bad` with `X-Bad: a<U+0001>b`. LeanIn's H1 parser accepts the control
byte; `Std.Http.Header.Value.ofString?` does not.

**Then.** The status is `400`, and the detector finds no `ran|` record with `target=/info?case=bad`.
