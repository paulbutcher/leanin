#!/usr/bin/env bash
# async-operands.sh — the compiled machine's receiver and read size are the ones the author named.
#
# A compiled relay reads exactly seven bytes from the first accepted connection and writes them to the second.
# The fixture sends ten bytes on the first and asserts the second receives exactly the first seven; a lowering
# that used the carried connection for the write, or the default 65536 for the read, fails here.
set -uo pipefail
cd "$(dirname "$0")/.."
lake build asyncRelay >/dev/null || { echo "async-operands: build failed" >&2; exit 1; }
port="${RELAY_PORT:-8795}"
./.lake/build/bin/asyncRelay "$port" >/tmp/async-operands.log 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; wait $pid 2>/dev/null' EXIT
for _ in $(seq 1 100); do
  ss -ltn 2>/dev/null | grep -q ":${port} " && break
  sleep 0.05
done
python3 - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
src = socket.create_connection(("127.0.0.1", port), timeout=5)
dst = socket.create_connection(("127.0.0.1", port), timeout=5)
src.sendall(b"0123456789")
dst.settimeout(5)
buf = b""
while len(buf) < 7:
    chunk = dst.recv(7 - len(buf))
    if not chunk:
        break
    buf += chunk
if buf != b"0123456":
    print(f"async-operands: FAIL expected 7 bytes on the second connection, got {buf!r}")
    sys.exit(1)
dst.settimeout(0.5)
extra = dst.recv(16)
if extra:
    print(f"async-operands: FAIL the read size was not honored; extra {extra!r}")
    sys.exit(1)
src.close(); dst.close()
PY
status=$?
wait $pid || status=1
[ "$status" -eq 0 ] && echo "async-operands: all checks passed"
exit "$status"
