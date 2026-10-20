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
check("path param", st.endswith("200 OK") and body == b"id=42 name=\n", f"{st} {body!r}")
check("middleware", b"X-Tag: users" in head, head.decode(errors="replace"))
st, _, body = get("/user/7?name=bob")
check("query param", st.endswith("200 OK") and body == b"id=7 name=bob\n", f"{st} {body!r}")

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

# Chunked request framing: two chunks plus a trailer, delivered across several reads.
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.settimeout(5)
s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n")
time.sleep(0.05)
s.sendall(b"5\r\nhello\r\n")
time.sleep(0.05)
s.sendall(b"6\r\n world\r\n0\r\nX-Trailer: y\r\n\r\n")
st, head, body = read_response(s)
check("chunked body", st.endswith("200 OK") and body == b"hello world", f"{st} {body!r}")
s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
st, _, body = read_response(s)
check("chunked keep-alive", st.endswith("200 OK") and body == b"abc", f"{st} {body!r}")
s.close()

# Expect: 100-continue gets the interim response before the body is sent.
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.settimeout(5)
s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n")
st, _, body = read_response(s)
check("100 continue", st.endswith("100 Continue") and body == b"", f"{st} {body!r}")
s.sendall(b"hello")
st, _, body = read_response(s)
check("body after continue", st.endswith("200 OK") and body == b"hello", f"{st} {body!r}")
s.close()

# The native route declaration syntax and its body extractor.
st, _, body = get("/nping")
check("native syntax", st.endswith("200 OK") and body == b"native-syntax\n", f"{st} {body!r}")
st, _, body = post("/ntodos", "application/json", b'{"title":"native","done":false}')
check("native syntax body extractor", st.endswith("200 OK") and b'"title":"native"' in body, f"{st} {body!r}")
st, _, body = get("/nuser/42")
check("native path extractor", st.endswith("200 OK") and body == b"id=42\n", f"{st} {body!r}")
st, _, body = post("/nform", "application/x-www-form-urlencoded", b"user=bob")
check("native form extractor", st.endswith("200 OK") and body == b"user=bob\n", f"{st} {body!r}")
# Parts extractors: method and version binders.
st, _, body = get("/method")
check("method/version extractors", st.endswith("200 OK") and body == b"GET HTTP/1.1\n", f"{st} {body!r}")

# Dual body extractor by media type.
st, _, body = post("/sum", "application/json", b'{"title":"sumjson","done":true}')
check("sum json", st.endswith("200 OK") and body == b"json:sumjson\n", f"{st} {body!r}")
st, _, body = post("/sum", "text/plain", b"sumtext")
check("sum text", st.endswith("200 OK") and body == b"text:sumtext\n", f"{st} {body!r}")

# Request scope: cleanup runs once after the response; a spawned child runs.
st, _, body = get("/cleanup")
check("cleanup route", st.endswith("200 OK") and body == b"scheduled\n", f"{st} {body!r}")
cleanup_seen = False
for _ in range(50):
    st, _, body = get("/counters")
    if b"cleanup=1" in body:
        cleanup_seen = True
        break
    time.sleep(0.02)
check("cleanup ran once", cleanup_seen, f"{st} {body!r}")
st2, _, body2 = get("/counters")
check("cleanup not repeated", b"cleanup=1" in body2, f"{st2} {body2!r}")
st, _, body = get("/child")
check("child route", st.endswith("200 OK") and body == b"spawned\n", f"{st} {body!r}")
child_seen = False
for _ in range(50):
    st, _, body = get("/counters")
    if b"child=1" in body:
        child_seen = True
        break
    time.sleep(0.02)
check("child ran", child_seen, f"{st} {body!r}")

# Range header extractor.
st, _, body = request(b"GET /range HTTP/1.1\r\nHost: x\r\nRange: bytes=0-4\r\n\r\n")
check("range extractor", st.endswith("200 OK") and body == b"ranges=true\n", f"{st} {body!r}")

# Stock-shaped request line.
st, _, body = request(b"GET /line HTTP/1.1\r\nHost: example.test\r\n\r\n")
check("request line view", st.endswith("200 OK") and body == b"GET /line host=example.test\n", f"{st} {body!r}")

# Native middleware: extensions, basic auth statuses.
st, _, body = get("/ext")
check("extension middleware", st.endswith("200 OK") and body == b"meta=hello\n", f"{st} {body!r}")
st, _, _ = get("/auth")
check("auth missing header", st.endswith("401 Unauthorized"), st)
st, _, _ = request(b"GET /auth HTTP/1.1\r\nHost: x\r\nAuthorization: Basic YWRtaW46d3Jvbmc=\r\n\r\n")
check("auth wrong password", st.endswith("403 Forbidden"), st)
st, _, body = request(b"GET /auth HTTP/1.1\r\nHost: x\r\nAuthorization: Basic YWRtaW46c2VjcmV0\r\n\r\n")
check("auth success", st.endswith("200 OK") and body == b"secret-area\n", f"{st} {body!r}")

# Stock-style response values and extractor binders under the unprefixed syntax.
st, _, body = get("/dropin")
check("dropin string", st.endswith("200 OK") and body == b"ok\n", f"{st} {body!r}")
st, _, body = get("/dropin-status")
check("dropin status tuple", st.endswith("201 Created") and body == b"made\n", f"{st} {body!r}")
st, _, body = get("/dropin/7")
check("dropin path extractor", st.endswith("200 OK") and body == b"id=7\n", f"{st} {body!r}")
st, _, body = post("/dropin-json", "application/json", b'{"title":"dropin","done":true}')
check("dropin json value", st.endswith("200 OK") and b'"title":"dropin"' in body, f"{st} {body!r}")

st, _, body = get("/nping-option")
check("option-selected syntax", st.endswith("200 OK") and body == b"option-native\n", f"{st} {body!r}")

# Multipart: two parts, one with a filename, parsed by the native backend.
boundary = "X-BOUNDARY"
parts = (
    f"--{boundary}\r\n"
    'Content-Disposition: form-data; name="user"\r\n\r\n'
    "alice\r\n"
    f"--{boundary}\r\n"
    'Content-Disposition: form-data; name="file"; filename="a.txt"\r\n'
    "Content-Type: text/plain\r\n\r\n"
    "hello file\r\n"
    f"--{boundary}--\r\n"
).encode()
raw = (f"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary={boundary}\r\n"
       f"Content-Length: {len(parts)}\r\n\r\n").encode() + parts
st, _, body = request(raw)
check("multipart parts", st.endswith("200 OK") and body == b"parts=2 user:-:5:text/plain file:a.txt:10:text/plain\n",
      f"{st} {body!r}")

# Multipart read incrementally, with the request split across writes.
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.settimeout(5)
s.sendall((f"POST /upload-stream HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary={boundary}\r\n"
           f"Content-Length: {len(parts)}\r\n\r\n").encode() + parts[:20])
time.sleep(0.05)
s.sendall(parts[20:])
st, _, body = read_response(s)
check("multipart streamed", st.endswith("200 OK") and body == b"streamed=2 user:5;file:10;\n",
      f"{st} {body!r}")
s.close()

# Part `save` writes each body to a file.
st, _, body = request(raw.replace(b"/upload ", b"/upload-save ", 1))
check("multipart saved", st.endswith("200 OK") and body == b"saved=2\n", f"{st} {body!r}")
try:
    p0 = open("/tmp/leanio-part-0","rb").read()
    p1 = open("/tmp/leanio-part-1","rb").read()
except OSError as e:
    p0 = p1 = b""
check("saved part bodies", p0 == b"alice" and p1 == b"hello file", f"{p0!r} {p1!r}")

# A client that disconnects while the handler is parked: the response write fails, the connection closes,
# and the server keeps serving.
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.sendall(b"GET /slow HTTP/1.1\r\nHost: x\r\n\r\n")
s.close()
time.sleep(0.35)
st, _, body = get("/ping")
check("alive after disconnecting a parked handler", st.endswith("200 OK") and body == b"pong\n",
      f"{st} {body!r}")

# A client that disconnects mid-body is a cancellation, not a 500 the server can still send; it must not take
# the server down or leave the connection loop wedged.
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 50\r\n\r\nshort")
s.close()
time.sleep(0.2)
st, _, body = get("/ping")
check("alive after mid-body close", st.endswith("200 OK") and body == b"pong\n", f"{st} {body!r}")

# HEAD is served by the GET handler with the body dropped and Content-Length: 0.
st, head, body = request(b"HEAD /ping HTTP/1.1\r\nHost: x\r\n\r\n")
check("HEAD from GET", st.endswith("200 OK") and body == b"" and b"content-length: 0" in head.lower(),
      f"{st} {head!r} {body!r}")

# Method contract.
st, _, _ = request(b"POST /ping HTTP/1.1\r\nHost: x\r\n\r\n")
check("known method, no route", st.endswith("405 Method Not Allowed"), st)
st, _, _ = request(b"FOOBAR /ping HTTP/1.1\r\nHost: x\r\n\r\n")
check("unknown method token", st.endswith("501 Not Implemented"), st)
st, _, _ = get("/nope")
check("miss", st.endswith("404 Not Found"), st)

# Error scope across a suspension: /boom sleeps then raises; the catch is around the park, and the
# connection still serves afterwards.
t0 = time.time()
st, _, body = get("/boom")
boom_dt = time.time() - t0
check("error scope across park", st.endswith("500 Internal Server Error") and boom_dt >= 0.09,
      f"{st} {boom_dt:.3f}s {body!r}")
st, _, body = get("/ping")
check("alive after caught error", st.endswith("200 OK") and body == b"pong\n", f"{st} {body!r}")

# Observing middleware logs the request and returns the response unchanged.
st, _, body = get("/logged")
check("logger passthrough", st.endswith("200 OK") and body == b"pong\n", f"{st} {body!r}")

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

try:
    log = open("/tmp/leanio-native.log", encoding="utf-8", errors="replace").read()
    check("logger line", "req GET /logged -> 200" in log, log[-200:])
except OSError as e:
    check("logger line", False, str(e))

if failures:
    print("leanio-native: FAILED")
    for f in failures:
        print("  " + f)
    sys.exit(1)
print("leanio-native: all checks passed")
PY
