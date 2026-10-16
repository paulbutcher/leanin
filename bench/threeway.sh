#!/usr/bin/env bash
# threeway.sh [C ...] — keep-alive echo-handler comparison: Node vs leanin vs the shipped Std.Http.Server.
#
#   nix develop -c bash bench/threeway.sh           # default levels: 1 8 32
#   nix develop -c bash bench/threeway.sh 1 4 16    # chosen levels
#
# Every arm runs on this box inside one invocation, in the same mode: a handler that builds a per-request
# response (leanin's own `reply`, the shipped server's, and `bench/node-server.mjs`), driven by `bench/load.mjs`
# in keep-alive for 5 s per level at path `/bench`. One row per (arm, level) — the client reports
# `rps`/`completed`/`errors`/`p50us`/`p99us`.
#
# Run it through `nix develop -c`: the `server` and `stdServer` binaries link the dev shell's libuv and fail
# silently without it. Read the ratios, not the absolute figures — docs/PERFORMANCE.md §4.7 measures this
# instrument's run-to-run spread at ±30 % — and take the reading only on a settled box: an earlier four-way of
# this shape was recorded at load average 4.8–6.0, where the doc itself notes the absolutes read depressed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

if [ "$#" -gt 0 ]; then levels=("$@"); else levels=(1 8 32); fi

run_arm() { # <label> <port> <cmd...>
  local label="$1" port="$2"
  shift 2
  "$@" >"/tmp/threeway_${port}.log" 2>&1 &
  local pid=$!
  sleep 2
  local resp
  resp="$(curl -s -m 3 "http://127.0.0.1:${port}/bench" | head -1)"
  if [ -z "$resp" ]; then
    echo "threeway: ${label} did not answer on ${port}; see /tmp/threeway_${port}.log" >&2
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 1
  fi
  printf '%-11s %s\n' "$label" "$resp"
  local c
  for c in "${levels[@]}"; do
    printf '%-11s C=%-3s %s\n' "$label" "$c" "$(node bench/load.mjs "$port" "$c" 5 /bench)"
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  sleep 0.5
}

run_arm "node" 8310 node bench/node-server.mjs 8310
run_arm "leanin" 8311 ./.lake/build/bin/server 8311 quiet
run_arm "lean-http" 8312 ./.lake/build/bin/stdServer 8312
