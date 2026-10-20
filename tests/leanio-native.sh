#!/usr/bin/env bash
# leanio-native.sh — the native LeanIO-on-LeanIn server, exercised at its public socket.
#
#   nix develop -c bash tests/leanio-native.sh
#
# Builds `leanioNative` (routes: GET /ping, GET /slow, GET /user/{id} with a tag middleware,
# POST /echo, /todos JSON, /text, /form), starts it on a port, and asserts the observable outcomes:
# routing and middleware, the suspended handler not blocking a sibling, buffered bodies across arrivals,
# keep-alive after a body, the method token contract, and the three extraction statuses.
set -uo pipefail
cd "$(dirname "$0")/.."
port="${LEANIO_PORT:-8799}"
lake build leanioNative >/dev/null || { echo "leanio-native: build failed" >&2; exit 1; }
./.lake/build/bin/leanioNative "$port" >/tmp/leanio-native.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; wait $srv 2>/dev/null' EXIT
for _ in $(seq 1 100); do
  ss -ltn 2>/dev/null | grep -q ":${port} " && break
  sleep 0.2
done

python3 - "$port" <<'PY'
import socket, sys, time

port = int(sys.argv[1])
failures = []

def check(name, cond, detail=""):
    if not cond:
        failures.append(f"{name}: {detail}")

def read_response(s):
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = s.recv(4096)
        if not d:
            break
        buf += d
    head, _, rest = buf.partition(b"\r\n\r\n")
    cl = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            cl = int(line.split(b":")[1])
    while len(rest) < cl:
        d = s.recv(4096)
        if not d:
            break
        rest += d
    status = head.split(b"\r\n")[0].decode() if head else ""
    return status, head, rest[:cl]

def request(raw):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.settimeout(5)
    s.sendall(raw)
    try:
        r = read_response(s)
    finally:
        s.close()
    return r

def post(path, ctype, body, extra=b""):
    raw = (f"POST {path} HTTP/1.1\r\nHost: x\r\nContent-Type: {ctype}\r\n"
           f"Content-Length: {len(body)}\r\n{extra.decode()}\r\n").encode() + body
    return request(raw)

def get(path):
    return request(f"GET {path} HTTP/1.1\r\nHost: x\r\n\r\n".encode())

# Routing, middleware, path parameters.
st, head, body = get("/user/42")
check("path param", st.endswith("200 OK") and body == b"id=42\n", f"{st} {body!r}")
check("middleware", b"X-Tag: users" in head, head.decode(errors="replace"))

# A suspended handler must not block a sibling.
t0 = time.time()
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.sendall(b"GET /slow HTTP/1.1\r\nHost: x\r\n\r\n")
time.sleep(0.05)
t1 = time.time()
st, _, body = get("/ping")
ping_dt = time.time() - t1
check("sibling while parked", ping_dt < 0.15 and body == b"pong\n", f"ping {ping_dt:.3f}s {body!r}")
s.settimeout(5)
st, _, body = read_response(s)
slow_dt = time.time() - t0
s.close()
check("slow parked", st.endswith("200 OK") and body == b"slept\n" and slow_dt >= 0.18,
      f"{st} {body!r} {slow_dt:.3f}s")

# A fragmented body, then a second request on the same connection.
body_text = b"hello world"
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.settimeout(5)
s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\n")
time.sleep(0.05); s.sendall(body_text[:6]); time.sleep(0.05); s.sendall(body_text[6:])
st, _, body = read_response(s)
check("fragmented body", st.endswith("200 OK") and body == body_text, f"{st} {body!r}")
s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\nnext")
st, _, body = read_response(s)
check("keep-alive after body", st.endswith("200 OK") and body == b"next", f"{st} {body!r}")
s.close()

# Method contract.
st, _, _ = request(b"POST /ping HTTP/1.1\r\nHost: x\r\n\r\n")
check("known method, no route", st.endswith("405 Method Not Allowed"), st)
st, _, _ = request(b"FOOBAR /ping HTTP/1.1\r\nHost: x\r\n\r\n")
check("unknown method token", st.endswith("501 Not Implemented"), st)
st, _, _ = get("/nope")
check("miss", st.endswith("404 Not Found"), st)

# Framing rejection.
st, _, _ = request(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 2097152\r\n\r\n")
check("oversized body", st.endswith("413 Payload Too Large"), st)

# Extraction statuses.
st, _, body = post("/todos", "application/json", b'{"title":"x","done":true}')
check("json ok", st.endswith("200 OK") and b'"title":"x"' in body, f"{st} {body!r}")
st, _, _ = post("/todos", "text/plain", b"{}")
check("json wrong mime", st.endswith("415 Unsupported Media Type"), st)
st, _, _ = post("/todos", "application/json", b"{oops}")
check("json malformed", st.endswith("400 Bad Request"), st)
st, _, _ = post("/todos", "application/json", b'{"done":true}')
check("json semantic", st.endswith("422 Unprocessable Entity"), st)
st, _, body = post("/text", "text/plain", b"hello")
check("text ok", st.endswith("200 OK") and body == b"text: hello\n", f"{st} {body!r}")
st, _, body = post("/form", "application/x-www-form-urlencoded", b"user=alice&x=1")
check("form ok", st.endswith("200 OK") and body == b"user=alice\n", f"{st} {body!r}")

if failures:
    print("leanio-native: FAILED")
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("leanio-native: all checks passed")
PY
