#!/usr/bin/env bash
# leanio-pair.sh [C ...] — paired, interleaved comparison of the LeanIn-backed LeanIO server against the
# shipped Std.Http.Server, which is the serving path upstream LeanIO was used with.
#
#   PAIRS=7 DURATION=5 nix develop -c bash bench/leanio-pair.sh 1 8 32
#
# Both arms answer GET /bench with the same bytes and keep-alive. Each round drives one arm then the other,
# alternating the order, so the pair sees the same host state; the reported ratio is the median of the
# per-round ratios and the two medians are context only. Server and client are pinned to distinct cores.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
lake build leanioNative stdServer >/dev/null || exit 1

if [ "$#" -gt 0 ]; then levels=("$@"); else levels=(1 8 32); fi
PAIRS="${PAIRS:-7}"
DURATION="${DURATION:-5}"
SERVER_CPU="${THREEWAY_SERVER_CPU:-1}"
CLIENT_CPU="${THREEWAY_CLIENT_CPU:-2}"
if [ "$(nproc 2>/dev/null || echo 0)" -lt 3 ]; then
  echo "leanio-pair: fewer than three cores; running unpinned (rows are not comparable)" >&2
  SERVER_CPU=""; CLIENT_CPU=""
fi
pin() { local cpu="$1"; shift; if [ -n "$cpu" ]; then exec taskset -c "$cpu" "$@"; else exec "$@"; fi }

std_port=8340
native_port=8341
std_pid=""; native_pid=""
stop_servers() {
  [ -n "$std_pid" ] && kill "$std_pid" 2>/dev/null && wait "$std_pid" 2>/dev/null
  [ -n "$native_pid" ] && kill "$native_pid" 2>/dev/null && wait "$native_pid" 2>/dev/null
  # A server that outlived its subshell would keep the port and silently replace the next arm.
  pkill -f "\.lake/build/bin/stdServer ${std_port}" 2>/dev/null
  pkill -f "\.lake/build/bin/leanioNative ${native_port}" 2>/dev/null
  std_pid=""; native_pid=""
}
trap stop_servers EXIT
start_servers() {
  for p in "$std_port" "$native_port"; do
    if ss -ltn 2>/dev/null | grep -q ":${p} " || pgrep -f "\.lake/build/bin/(stdServer|leanioNative) ${p}" >/dev/null; then
      echo "leanio-pair: port ${p} is already in use; refusing to measure another process" >&2
      exit 1
    fi
  done
  pin "$SERVER_CPU" ./.lake/build/bin/stdServer "$std_port" >/tmp/leanio_pair_std.log 2>&1 &
  std_pid=$!
  pin "$SERVER_CPU" ./.lake/build/bin/leanioNative "$native_port" >/tmp/leanio_pair_native.log 2>&1 &
  native_pid=$!
  sleep 2
  for p in "$std_port" "$native_port"; do
    if [ -z "$(curl -s -m 3 "http://127.0.0.1:${p}/bench" | head -1)" ]; then
      echo "leanio-pair: nothing answered on ${p}" >&2
      exit 1
    fi
  done
}
median() { sort -n | awk '{a[NR]=$1} END {if (NR==0) print 0; else if (NR%2) print a[(NR+1)/2]; else printf "%.0f\n", (a[NR/2]+a[NR/2+1])/2}'
}
iqr() { sort -n | awk '{a[NR]=$1} END {if (NR<2) {print a[1], a[1]} else {printf "%.3f %.3f\n", a[int(NR*0.25)+1], a[int(NR*0.75)+1]}}'
}

printf 'leanio-pair: %d rounds per level, %ss per arm, std :%s vs native :%s\n' \
  "$PAIRS" "$DURATION" "$std_port" "$native_port"
for c in "${levels[@]}"; do
  stop_servers
  start_servers
  : >/tmp/leanio_pair_ratio.txt
  : >/tmp/leanio_pair_std_rps.txt
  : >/tmp/leanio_pair_native_rps.txt
  for r in $(seq 1 "$PAIRS"); do
    if [ $((r % 2)) -eq 1 ]; then
      s=$(pin "$CLIENT_CPU" node bench/load.mjs "$std_port" "$c" "$DURATION" /bench | grep -o 'rps=[0-9]*' | cut -d= -f2)
      n=$(pin "$CLIENT_CPU" node bench/load.mjs "$native_port" "$c" "$DURATION" /bench | grep -o 'rps=[0-9]*' | cut -d= -f2)
    else
      n=$(pin "$CLIENT_CPU" node bench/load.mjs "$native_port" "$c" "$DURATION" /bench | grep -o 'rps=[0-9]*' | cut -d= -f2)
      s=$(pin "$CLIENT_CPU" node bench/load.mjs "$std_port" "$c" "$DURATION" /bench | grep -o 'rps=[0-9]*' | cut -d= -f2)
    fi
    if [ -z "$s" ] || [ -z "$n" ] || [ "$s" -eq 0 ]; then
      echo "C=$c round $r: missing reading (std=$s native=$n)" >&2
      continue
    fi
    echo "C=$c round $r std=$s native=$n ratio=$(awk -v n="$n" -v s="$s" 'BEGIN{printf "%.3f", n/s}')"
    awk -v n="$n" -v s="$s" 'BEGIN{printf "%.4f\n", n/s}' >>/tmp/leanio_pair_ratio.txt
    echo "$s" >>/tmp/leanio_pair_std_rps.txt
    echo "$n" >>/tmp/leanio_pair_native_rps.txt
  done
  rat_med=$(median </tmp/leanio_pair_ratio.txt)
  rat_iqr=$(iqr </tmp/leanio_pair_ratio.txt)
  std_med=$(median </tmp/leanio_pair_std_rps.txt)
  native_med=$(median </tmp/leanio_pair_native_rps.txt)
  printf 'C=%-3s median ratio native/std=%s (IQR %s); medians std=%s native=%s\n' \
    "$c" "$rat_med" "$rat_iqr" "$std_med" "$native_med"
done
