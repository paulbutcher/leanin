#!/usr/bin/env bash
# Multi-carrier serving: the listener's pump thread serves the loop while `workers` carriers run.
set -euo pipefail
cd "$(dirname "$0")/.."
port="${MULTI_PORT:-$((8800 + ($$ % 900)))}"
lake build server >/dev/null
./.lake/build/bin/server "$port" workers=2 count=8 quiet >/tmp/multi-server.log 2>&1 &
srv=$!
trap 'kill -9 $srv 2>/dev/null || true; wait $srv 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do
  ss -ltn 2>/dev/null | grep -q ":${port} " && break
  sleep 0.2
done
python3 - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
bad = 0
for _ in range(8):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.settimeout(5)
    s.sendall(b"GET /multi HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    buf = b""
    while True:
        d = s.recv(4096)
        if not d: break
        buf += d
    head, _, _ = buf.partition(b"\r\n\r\n")
    if b"200 OK" not in head: bad += 1
    s.close()
if bad:
    print(f"multi-server: {bad} failed responses"); sys.exit(1)
print("multi-server: all responses 200")
PY
wait $srv
echo "multi-server: ok"
