#!/usr/bin/env bash
# http-stream.sh — the streaming handler at its public socket.
#
#   nix develop -c bash tests/http-stream.sh
#
# Builds `streamEcho`, serves it, and asserts: a chunked response for a GET; a chunked request echoed
# incrementally, including one split across writes; a fixed-length body far past the buffered limit; and a
# client that disconnects mid-body not taking the server down.
set -uo pipefail
cd "$(dirname "$0")/.."
port="${STREAM_PORT:-8790}"
lake build streamEcho >/dev/null || { echo "http-stream: build failed" >&2; exit 1; }
./.lake/build/bin/streamEcho "$port" >/tmp/http-stream.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; wait $srv 2>/dev/null' EXIT
for _ in $(seq 1 100); do
  ss -ltn 2>/dev/null | grep -q ":${port} " && break
  sleep 0.2
done

python3 - "$port" <<'PY'
import socket, sys

port = int(sys.argv[1])
failures = []

def check(name, cond, detail=""):
    if not cond:
        failures.append(f"{name}: {detail}")

def recv_head(s):
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = s.recv(4096)
        if not d:
            break
        buf += d
    head, _, rest = buf.partition(b"\r\n\r\n")
    return head.decode(), rest

def recv_chunked(s, rest=b""):
    body = b""
    buf = rest
    while True:
        while b"\r\n" not in buf:
            d = s.recv(65536)
            if not d:
                return body, "eof"
            buf += d
        line, _, buf = buf.partition(b"\r\n")
        n = int(line.split(b";")[0], 16)
        while len(buf) < n + 2:
            d = s.recv(65536)
            if not d:
                return body, "eof-in-chunk"
            buf += d
        body += buf[:n]
        buf = buf[n+2:]
        if n == 0:
            return body, "ok"

def connect():
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.settimeout(5)
    return s

# A GET answers one chunk through a chunked response.
s = connect()
s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
head, rest = recv_head(s)
body, how = recv_chunked(s, rest)
check("get chunked", "200 OK" in head and "chunked" in head.lower() and body == b"hello\n" and how == "ok",
      f"{head!r} {body!r} {how}")
s.close()

# A chunked request is decoded incrementally and echoed as it arrives: the first response chunk is readable
# before the request has ended.
s = connect()
s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n")
s.sendall(b"5\r\nhello\r\n")
head, rest = recv_head(s)
buf = rest
while b"\r\n" not in buf:
    buf += s.recv(65536)
line, _, buf = buf.partition(b"\r\n")
n = int(line, 16)
while len(buf) < n + 2:
    buf += s.recv(65536)
first = buf[:n]
check("streamed before request ends", "200 OK" in head and first == b"hello",
      f"{head!r} {first!r}")
s.sendall(b"6\r\n world\r\n0\r\n\r\n")
body = first
buf = buf[n+2:]
while True:
    while b"\r\n" not in buf:
        buf += s.recv(65536)
    line, _, buf = buf.partition(b"\r\n")
    n = int(line, 16)
    while len(buf) < n + 2:
        buf += s.recv(65536)
    body += buf[:n]
    buf = buf[n+2:]
    if n == 0:
        break
check("rest after request ends", body == b"hello world", f"{body!r}")
s.close()

# A body past the buffered limit is streamed whole, in both directions.
payload = bytes((i * 7 + 3) % 251 for i in range(2 * 1024 * 1024))
s = connect()
s.sendall(f"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: {len(payload)}\r\n\r\n".encode())
for i in range(0, len(payload), 131072):
    s.sendall(payload[i:i+131072])
head, rest = recv_head(s)
body, how = recv_chunked(s, rest)
check("2 MiB streamed", "200 OK" in head and body == payload and how == "ok",
      f"{head!r} len={len(body)} {how}")
s.close()

# A declared body over the configured ceiling is rejected with 413 before it is read.
s = connect()
s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5242880\r\n\r\n")
head, rest = recv_head(s)
check("413 over limit", "413" in head and "Payload Too Large" in head, f"{head!r}")
s.close()

# A handler parked in a sleep is cancelled by its request scope: no response bytes and EOF.
s = connect()
s.settimeout(3)
s.sendall(b"GET /slow HTTP/1.1\r\nHost: x\r\n\r\n")
try:
    early = s.recv(4096)
except socket.timeout:
    early = b"<timeout>"
check("request scope cancels a parked handler", early == b"", f"{early!r}")
s.close()

# A client that dies mid-body does not take the server down.
s = connect()
s.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\nshort")
s.close()
s = connect()
s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
head, rest = recv_head(s)
body, how = recv_chunked(s, rest)
check("alive after mid-body disconnect", "200 OK" in head and body == b"hello\n", f"{head!r} {body!r}")
s.close()

if failures:
    print("http-stream: FAIL")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("http-stream: all checks passed")
PY
