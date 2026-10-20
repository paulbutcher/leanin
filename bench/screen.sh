#!/usr/bin/env bash
# screen.sh — one server per arm, three load shapes, at each connection level.
#
#   nix develop -c bash bench/screen.sh
#
# Shapes:
#   d1     keep-alive, one request in flight per connection (latency-bound)
#   p16    keep-alive, sixteen requests in flight per connection (throughput/CPU-bound)
#   churn  one connection per request (setup/teardown and the close path)
#
# Every arm runs on this box, each server started fresh for the arm, server and client pinned to distinct cores
# as in threeway.sh/paired.sh. The rows are single readings: read them as shape and order, not as precise
# ratios — use paired.sh for a claim about one arm against another.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

lake build server stdServer >/dev/null || exit 1

levels=(1 8 32)
DUR="${DUR:-5}"
SERVER_CPU="${THREEWAY_SERVER_CPU:-1}"
CLIENT_CPU="${THREEWAY_CLIENT_CPU:-2}"
if [ "$(nproc 2>/dev/null || echo 0)" -lt 3 ]; then
  echo "screen: fewer than three cores; running unpinned (rows are not comparable)" >&2
  SERVER_CPU=""; CLIENT_CPU=""
fi
pin() { local cpu="$1"; shift; if [ -n "$cpu" ]; then taskset -c "$cpu" "$@"; else "$@"; fi; }

run_arm() { # <label> <port> <cmd...>
  local label="$1" port="$2"
  shift 2
  pin "$SERVER_CPU" "$@" >"/tmp/screen_${port}.log" 2>&1 &
  local pid=$!
  sleep 2
  if [ -z "$(curl -s -m 3 "http://127.0.0.1:${port}/" | head -1)" ]; then
    echo "screen: ${label} did not answer on ${port}" >&2
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    return 1
  fi
  for level in "${levels[@]}"; do
    printf '%-6s d1    C=%-3s %s\n' "$label" "$level" \
      "$(pin "$CLIENT_CPU" node bench/load.mjs "$port" "$level" "$DUR" /bench)"
    printf '%-6s p16   C=%-3s %s\n' "$label" "$level" \
      "$(pin "$CLIENT_CPU" env LOAD_PIPE=16 node bench/load.mjs "$port" "$level" "$DUR" /bench)"
    printf '%-6s churn C=%-3s %s\n' "$label" "$level" \
      "$(pin "$CLIENT_CPU" node bench/churn.mjs "$port" "$level" "$DUR" /bench)"
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  sleep 0.5
}

run_arm node 8310 node bench/node-server.mjs 8310
run_arm leanin 8311 ./.lake/build/bin/server 8311 quiet
run_arm std 8312 ./.lake/build/bin/stdServer 8312
