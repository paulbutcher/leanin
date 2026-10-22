#!/usr/bin/env bash
#
# Behaviour checks for `Std.Http`-shaped handlers, at the `stdEcho` executable's socket. The scenarios are
# stated in `tests/std-handler-contract.md`.
#
# A setup failure — the build, the server not listening, a malformed record, an affirmative control that does
# not hold — exits 2. A scenario assertion that does not hold exits 1.
#
# Usage, from the repository root:
#   nix develop -c bash tests/std-handler-contract.sh SH1

set -uo pipefail
cd "$(dirname "$0")/.." || {
  echo "setup error: cannot enter the repository" >&2
  exit 2
}

scenario="${1:-}"
case "$scenario" in
SH1 | SH2 | SH3 | SH4) ;;
*)
  echo "setup error: usage: $0 SH1|SH2|SH3|SH4" >&2
  exit 2
  ;;
esac

port="${STD_PORT:-8794}"
log="$(mktemp)"
lake build stdEcho >/dev/null || {
  echo "setup error: stdEcho did not build" >&2
  exit 2
}
./.lake/build/bin/stdEcho "$port" >"$log" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; wait $srv 2>/dev/null; rm -f "$log"' EXIT
for _ in $(seq 1 100); do
  grep -q '^listening|' "$log" && break
  sleep 0.1
done
grep -q '^listening|' "$log" || {
  echo "setup error: stdEcho is not listening" >&2
  cat "$log" >&2
  exit 2
}

python3 -I - "$scenario" "$port" "$log" <<'PY'
import re, socket, sys, time

scenario, port, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]

def fail(msg):
    print(f"{scenario}: FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

def setup_error(msg):
    print(f"{scenario}: setup error: {msg}", file=sys.stderr)
    sys.exit(2)

def records(kind):
    """The handler's records of one kind, each as a dict of its named fields."""
    out = []
    with open(log, "rb") as f:
        for raw in f.read().decode("utf-8", "replace").splitlines():
            parts = raw.split("|")
            if parts[0] != kind:
                continue
            fields = {}
            for p in parts[1:]:
                if "=" not in p:
                    setup_error(f"malformed record {raw!r}")
                k, _, v = p.partition("=")
                fields[k] = v
            out.append(fields)
    return out

def ran(target):
    """The absence detector: a `ran|` record whose `target` field is exactly `target`."""
    return any(r.get("target") == target for r in records("ran"))

def connect():
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.settimeout(5)
    return s

def recv_head(s, buf=b""):
    while b"\r\n\r\n" not in buf:
        d = s.recv(4096)
        if not d:
            return None, buf
        buf += d
    head, _, rest = buf.partition(b"\r\n\r\n")
    return head.decode("latin-1"), rest

def status(head):
    return int(head.split("\r\n")[0].split(" ")[1])

def header(head, name):
    for line in head.split("\r\n")[1:]:
        n, _, v = line.partition(":")
        if n.strip().lower() == name:
            return v.strip()
    return None

def recv_body(s, head, rest):
    n = header(head, "content-length")
    if n is not None:
        n = int(n)
        while len(rest) < n:
            d = s.recv(65536)
            if not d:
                break
            rest += d
        return rest[:n]
    body, buf = b"", rest
    while True:
        while b"\r\n" not in buf:
            buf += s.recv(65536)
        line, _, buf = buf.partition(b"\r\n")
        k = int(line.split(b";")[0], 16)
        while len(buf) < k + 2:
            buf += s.recv(65536)
        body += buf[:k]
        buf = buf[k + 2:]
        if k == 0:
            return body

def exchange(req):
    s = connect()
    s.sendall(req)
    head, rest = recv_head(s)
    if head is None:
        s.close()
        return None, None
    body = recv_body(s, head, rest)
    s.close()
    return head, body

def body_fields(body):
    return dict(p.partition("=")[::2] for p in body.decode().strip().split("|"))

IMF_FIXDATE = re.compile(r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{2} "
                         r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} \d{2}:\d{2}:\d{2} GMT$")

if scenario == "SH1":
    head, body = exchange(b"GET /info?q=1 HTTP/1.1\r\nHost: x\r\nX-Multi: a\r\nX-Multi: b\r\n\r\n")
    if head is None:
        fail("no response")
    if status(head) != 200:
        fail(f"status {status(head)}, expected 200: {head!r}")
    f = body_fields(body)
    if f.get("method") != "GET" or f.get("target") != "/info?q=1":
        fail(f"method/target {f.get('method')!r} {f.get('target')!r}")
    if f.get("x-multi") != "a,b":
        fail(f"x-multi {f.get('x-multi')!r}, expected 'a,b'")
    if not f.get("remote", "").startswith("127.0.0.1:"):
        fail(f"remote {f.get('remote')!r}, expected the RemoteAddr extension for 127.0.0.1")
    date = header(head, "date")
    if date is None or not IMF_FIXDATE.match(date):
        fail(f"Date header {date!r} is absent or not IMF-fixdate")

elif scenario == "SH2":
    # Affirmative control for the absence detector.
    s = connect()
    s.sendall(b"POST /accept HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n")
    h100, rest = recv_head(s)
    if h100 is None or status(h100) != 100:
        setup_error(f"control: expected 100 Continue, got {h100!r}")
    s.sendall(b"hello")
    head, rest = recv_head(s, rest)
    if head is None or status(head) != 200 or recv_body(s, head, rest) != b"hello":
        setup_error(f"control: expected 200 hello, got {head!r}")
    s.close()
    if not ran("/accept"):
        setup_error("control: the detector did not find the accepted request's ran| record")
    # The scenario.
    s = connect()
    s.sendall(b"POST /refuse HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n")
    head, rest = recv_head(s)
    if head is None:
        fail("no response head")
    if status(head) != 417:
        fail(f"first response head is {head.splitlines()[0]!r}, expected 417 Expectation Failed")
    recv_body(s, head, rest)
    try:
        after = s.recv(4096)
    except socket.timeout:
        after = None
    s.close()
    if after != b"":
        fail(f"the connection was not closed after the 417 (read {after!r})")
    if ran("/refuse"):
        fail("the handler ran for the refused request")

elif scenario == "SH3":
    def failures():
        return records("failure")
    def wait_count(n, bound=5.0):
        end = time.monotonic() + bound
        while time.monotonic() < end and len(failures()) < n:
            time.sleep(0.05)
        return len(failures())
    if failures():
        setup_error("failure records before the scenario started")
    head, _ = exchange(b"GET /throw HTTP/1.1\r\nHost: x\r\n\r\n")
    if head is None or status(head) != 500:
        fail(f"/throw answered {head!r}, expected 500")
    if wait_count(1) != 1:
        fail(f"after a handler error, {len(failures())} failure records, expected 1")
    if failures()[0].get("err") != "boom":
        fail(f"failure record {failures()[0]!r}, expected err=boom")
    head, _ = exchange(b"GET /info HTTP/1.1\r\nHost: x\r\n\r\n")
    if head is None or status(head) != 200:
        setup_error(f"clean request answered {head!r}")
    if len(failures()) != 1:
        fail(f"a clean request added a failure record: {failures()!r}")
    s = connect()
    s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nshort")
    s.close()
    if wait_count(2) != 2:
        fail(f"after a mid-body disconnect, {len(failures())} failure records, expected 2")
    head, _ = exchange(b"GET /info HTTP/1.1\r\nHost: x\r\n\r\n")
    if head is None or status(head) != 200:
        setup_error(f"clean request after the disconnect answered {head!r}")
    if len(failures()) != 2:
        fail(f"the transport failure was reported {len(failures()) - 1} times: {failures()!r}")

elif scenario == "SH4":
    head, _ = exchange(b"GET /info?case=good HTTP/1.1\r\nHost: x\r\nX-Bad: ab\r\n\r\n")
    if head is None or status(head) != 200 or not ran("/info?case=good"):
        setup_error(f"control: expected 200 and a ran| record for the valid head, got {head!r}")
    head, _ = exchange(b"GET /info?case=bad HTTP/1.1\r\nHost: x\r\nX-Bad: a\x01b\r\n\r\n")
    if head is None:
        fail("no response")
    if status(head) != 400:
        fail(f"status {status(head)}, expected 400 Bad Request")
    if ran("/info?case=bad"):
        fail("the handler ran for a head Std rejects")

print(f"{scenario}: passed")
PY
