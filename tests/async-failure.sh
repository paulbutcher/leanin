#!/usr/bin/env bash
# async-failure.sh — a failed send's policy is the same whether its result is bound or discarded.
#
# The peer resets the connection with SO_LINGER(0); the machine waits 200 ms, then writes a megabyte, so the
# write fails. The unbound machine must still reach its terminal (before the repair it ended the path silently);
# the bound one must observe the failure. A watchdog bounds the wait.
set -uo pipefail
cd "$(dirname "$0")/.."
lake build asyncFailure >/dev/null || { echo "async-failure: build failed" >&2; exit 1; }
port="${FAILURE_PORT:-8799}"
timeout 20 ./.lake/build/bin/asyncFailure "$port" >/tmp/async-failure.log 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; wait $pid 2>/dev/null' EXIT
for _ in $(seq 1 200); do
  ss -ltn 2>/dev/null | grep -q ":${port} " && break
  sleep 0.05
done
python3 - "$port" <<'PY'
import socket, struct, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
s.close()
PY
if wait $pid; then
  grep -q "bound observed the failure" /tmp/async-failure.log || {
    cat /tmp/async-failure.log; echo "async-failure: FAIL the write did not fail as required"; exit 1; }
  echo "async-failure: all checks passed"
else
  cat /tmp/async-failure.log
  echo "async-failure: FAIL"
  exit 1
fi
