#!/usr/bin/env bash
# drain.sh — stop admission and drain an in-flight request.
set -uo pipefail
cd "$(dirname "$0")/.."
port="${DRAIN_PORT:-8823}"
lake build leanioDrain >/dev/null || { echo "drain: build failed" >&2; exit 1; }
./.lake/build/bin/leanioDrain "$port" 1500 >/tmp/leanio-drain.log 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; wait $srv 2>/dev/null' EXIT
for _ in $(seq 1 200); do ss -ltn 2>/dev/null | grep -q ":${port} " && break; sleep 0.05; done
python3 - "$port" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.settimeout(5)
t0 = time.time()
s.sendall(b"GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
buf = b""
while b"\r\n\r\n" not in buf:
    d = s.recv(4096)
    if not d: break
    buf += d
head, _, rest = buf.partition(b"\r\n\r\n")
cl = 0
for line in head.split(b"\r\n"):
    if line.lower().startswith(b"content-length:"):
        cl = int(line.split(b":")[1])
while len(rest) < cl:
    d = s.recv(4096)
    if not d: break
    rest += d
s.close()
dt = time.time() - t0
if b"200 OK" not in head or rest[:cl] != b"slow\n" or dt < 0.25:
    print(f"drain: FAIL {head!r} {rest!r} dt={dt:.3f}")
    sys.exit(1)
PY
status=$?
wait $srv || true
grep -q drained /tmp/leanio-drain.log || { echo "drain: server did not drain"; exit 1; }
[ "$status" -eq 0 ] && echo "drain: all checks passed"
exit "$status"
