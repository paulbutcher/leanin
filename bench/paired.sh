#!/usr/bin/env bash
# paired.sh [levels...] — interleaved, paired keep-alive comparison: Node vs leanin's compiled driver.
#
#   PAIRS=9 DURATION=5 nix develop -c bash bench/paired.sh 1 8 32
#
# Why paired: this instrument's absolute rows move by tens of percent with the host's state, but a pair taken
# back to back sees the same state, so the *ratio within a pair* is stable where the rows are not. Both servers
# stay up for the whole run; each round drives one arm after the other, alternating which goes first so neither
# pays a consistent warm-up or scheduling position. The reported ratio is the median of the per-round ratios,
# with the interquartile range; the per-arm medians are shown for context only.
#
# Both sides are pinned to distinct P-cores and the energy-performance preference should be `performance`, as in
# threeway.sh. Override THREEWAY_SERVER_CPU / THREEWAY_CLIENT_CPU on another host with different topology.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

lake build server >/dev/null || exit 1

if [ "$#" -gt 0 ]; then levels=("$@"); else levels=(1 8 32); fi
PAIRS="${PAIRS:-7}"
DURATION="${DURATION:-5}"

SERVER_CPU="${THREEWAY_SERVER_CPU:-1}"
CLIENT_CPU="${THREEWAY_CLIENT_CPU:-2}"
if [ "$(nproc 2>/dev/null || echo 0)" -lt 3 ]; then
  echo "paired: fewer than three cores; running unpinned (rows are not comparable)" >&2
  SERVER_CPU=""
  CLIENT_CPU=""
fi
pin() { local cpu="$1"; shift; if [ -n "$cpu" ]; then taskset -c "$cpu" "$@"; else "$@"; fi }

node_port=8320
leanin_port=8321
node_pid=""
leanin_pid=""
stop_servers() {
  [ -n "$node_pid" ] && kill "$node_pid" 2>/dev/null && wait "$node_pid" 2>/dev/null
  [ -n "$leanin_pid" ] && kill "$leanin_pid" 2>/dev/null && wait "$leanin_pid" 2>/dev/null
  node_pid=""; leanin_pid=""
}
trap stop_servers EXIT
# Each level starts both servers fresh: a server that has already served a level carries heap and connection
# state into the next, which showed up as Node's C=32 rows falling ~30 % over a long run while ours held.
start_servers() {
  pin "$SERVER_CPU" node bench/node-server.mjs "$node_port" >/tmp/paired_node.log 2>&1 &
  node_pid=$!
  pin "$SERVER_CPU" ./.lake/build/bin/server "$leanin_port" quiet >/tmp/paired_leanin.log 2>&1 &
  leanin_pid=$!
  sleep 2
  for p in "$node_port" "$leanin_port"; do
    if [ -z "$(curl -s -m 3 "http://127.0.0.1:${p}/bench" | head -1)" ]; then
      echo "paired: nothing answered on ${p}" >&2
      exit 1
    fi
  done
}

median() { # stdin: one number per line
  sort -n | awk '{a[NR]=$1} END {if (NR==0) print 0; else if (NR%2) print a[(NR+1)/2]; else printf "%.0f\n", (a[NR/2]+a[NR/2+1])/2}'
}
iqr() { # stdin: one number per line; prints "q1 q3"
  sort -n | awk '{a[NR]=$1} END {if (NR<2) {print a[1], a[1]} else {printf "%.3f %.3f\n", a[int(NR*0.25)+1], a[int(NR*0.75)+1]}}'
}

printf 'paired: %d rounds per level, %ss per arm, node :%s vs leanin :%s\n' \
  "$PAIRS" "$DURATION" "$node_port" "$leanin_port"
for c in "${levels[@]}"; do
  stop_servers
  start_servers
  : >/tmp/paired_ratio.txt
  : >/tmp/paired_node_rps.txt
  : >/tmp/paired_leanin_rps.txt
  for r in $(seq 1 "$PAIRS"); do
    if [ $((r % 2)) -eq 1 ]; then
      n=$(pin "$CLIENT_CPU" node bench/load.mjs "$node_port" "$c" "$DURATION" /bench | grep -o 'rps=[0-9]*' | cut -d= -f2)
      l=$(pin "$CLIENT_CPU" node bench/load.mjs "$leanin_port" "$c" "$DURATION" /bench | grep -o 'rps=[0-9]*' | cut -d= -f2)
    else
      l=$(pin "$CLIENT_CPU" node bench/load.mjs "$leanin_port" "$c" "$DURATION" /bench | grep -o 'rps=[0-9]*' | cut -d= -f2)
      n=$(pin "$CLIENT_CPU" node bench/load.mjs "$node_port" "$c" "$DURATION" /bench | grep -o 'rps=[0-9]*' | cut -d= -f2)
    fi
    if [ -z "$n" ] || [ -z "$l" ] || [ "$n" -eq 0 ]; then
      echo "C=$c round $r: missing reading (node=$n leanin=$l)" >&2
      continue
    fi
    echo "C=$c round $r node=$n leanin=$l ratio=$(awk -v l="$l" -v n="$n" 'BEGIN{printf "%.3f", l/n}')"
    awk -v l="$l" -v n="$n" 'BEGIN{printf "%.4f\n", l/n}' >>/tmp/paired_ratio.txt
    echo "$n" >>/tmp/paired_node_rps.txt
    echo "$l" >>/tmp/paired_leanin_rps.txt
  done
  rat_med=$(median </tmp/paired_ratio.txt)
  rat_iqr=$(iqr </tmp/paired_ratio.txt)
  node_med=$(median </tmp/paired_node_rps.txt)
  leanin_med=$(median </tmp/paired_leanin_rps.txt)
  printf 'C=%-3s median ratio leanin/node=%s (IQR %s); medians node=%s leanin=%s\n' \
    "$c" "$rat_med" "$rat_iqr" "$node_med" "$leanin_med"
  : >/tmp/paired_node_rps.txt
  : >/tmp/paired_leanin_rps.txt
done
