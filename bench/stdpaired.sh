#!/usr/bin/env bash
# stdpaired.sh [levels...] — interleaved, paired keep-alive comparison: the `Std`-shaped handler layer against the
# native stream handler, both served by `stdBench` through the same streaming driver.
#
#   PAIRS=9 DURATION=5 nix develop -c nix shell nixpkgs#nodejs -c bash bench/stdpaired.sh 1 8 32
#
# The method is paired.sh's: both servers stay up for a level, each round drives one arm after the other,
# alternating which goes first, and the reported ratio (std/native) is the median of the per-round ratios with its
# interquartile range. Both servers share one pinned core and the client another, as in paired.sh.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

lake build stdBench >/dev/null || exit 1

if [ "$#" -gt 0 ]; then levels=("$@"); else levels=(1 8 32); fi
PAIRS="${PAIRS:-7}"
DURATION="${DURATION:-5}"

SERVER_CPU="${THREEWAY_SERVER_CPU:-1}"
CLIENT_CPU="${THREEWAY_CLIENT_CPU:-2}"
if [ "$(nproc 2>/dev/null || echo 0)" -lt 3 ]; then
  echo "stdpaired: fewer than three cores; running unpinned (rows are not comparable)" >&2
  SERVER_CPU=""
  CLIENT_CPU=""
fi
pin() {
  local cpu="$1"
  shift
  if [ -n "$cpu" ]; then taskset -c "$cpu" "$@"; else "$@"; fi
}

native_port=8322
std_port=8323
native_pid=""
std_pid=""
stop_servers() {
  [ -n "$native_pid" ] && kill "$native_pid" 2>/dev/null && wait "$native_pid" 2>/dev/null
  [ -n "$std_pid" ] && kill "$std_pid" 2>/dev/null && wait "$std_pid" 2>/dev/null
  native_pid=""
  std_pid=""
}
trap stop_servers EXIT
port_taken() { ss -ltn 2>/dev/null | grep -q ":$1 "; }
# Started directly rather than through `pin`: a backgrounded shell function is a subshell, so `$!` would be that
# subshell and `kill` would leave the server running — holding its port, so the next level's server would fail
# to bind while the stale one answered the health check below.
serve_pinned() { # <cpu> <cmd...>; sets started_pid
  local cpu="$1"
  shift
  if [ -n "$cpu" ]; then taskset -c "$cpu" "$@" & else "$@" & fi
  started_pid=$!
}
start_servers() {
  for p in "$native_port" "$std_port"; do
    if port_taken "$p"; then
      echo "stdpaired: port ${p} is already in use; a stale server would be measured" >&2
      exit 1
    fi
  done
  serve_pinned "$SERVER_CPU" ./.lake/build/bin/stdBench "$native_port" native >/tmp/stdpaired_native.log 2>&1
  native_pid=$started_pid
  serve_pinned "$SERVER_CPU" ./.lake/build/bin/stdBench "$std_port" std >/tmp/stdpaired_std.log 2>&1
  std_pid=$started_pid
  sleep 2
  for p in "$native_port" "$std_port"; do
    if [ -z "$(curl -s -m 3 "http://127.0.0.1:${p}/bench" | head -1)" ]; then
      echo "stdpaired: nothing answered on ${p}" >&2
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
rps() { pin "$CLIENT_CPU" node bench/load.mjs "$1" "$2" "$DURATION" /bench | grep -o 'rps=[0-9]*' | cut -d= -f2; }

printf 'stdpaired: %d rounds per level, %ss per arm, native :%s vs std :%s\n' \
  "$PAIRS" "$DURATION" "$native_port" "$std_port"
for c in "${levels[@]}"; do
  stop_servers
  start_servers
  : >/tmp/stdpaired_ratio.txt
  : >/tmp/stdpaired_native_rps.txt
  : >/tmp/stdpaired_std_rps.txt
  for r in $(seq 1 "$PAIRS"); do
    if [ $((r % 2)) -eq 1 ]; then
      n=$(rps "$native_port" "$c")
      s=$(rps "$std_port" "$c")
    else
      s=$(rps "$std_port" "$c")
      n=$(rps "$native_port" "$c")
    fi
    if [ -z "$n" ] || [ -z "$s" ] || [ "$n" -eq 0 ]; then
      echo "C=$c round $r: missing reading (native=$n std=$s)" >&2
      continue
    fi
    echo "C=$c round $r native=$n std=$s ratio=$(awk -v s="$s" -v n="$n" 'BEGIN{printf "%.3f", s/n}')"
    awk -v s="$s" -v n="$n" 'BEGIN{printf "%.4f\n", s/n}' >>/tmp/stdpaired_ratio.txt
    echo "$n" >>/tmp/stdpaired_native_rps.txt
    echo "$s" >>/tmp/stdpaired_std_rps.txt
  done
  printf 'C=%-3s median ratio std/native=%s (IQR %s); medians native=%s std=%s\n' \
    "$c" "$(median </tmp/stdpaired_ratio.txt)" "$(iqr </tmp/stdpaired_ratio.txt)" \
    "$(median </tmp/stdpaired_native_rps.txt)" "$(median </tmp/stdpaired_std_rps.txt)"
done
