#!/usr/bin/env bash
# A connection parked in a 60 s sleep must be aborted at the drain deadline, and the accept loop
# must return with every registered connection task settled.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(nix develop -c lake exe drainDeadline)
echo "$out"
grep -q 'returned=yes' <<<"$out"
elapsed=$(sed -n 's/.*elapsedMs=\([0-9]*\).*/\1/p' <<<"$out")
test -n "$elapsed" && test "$elapsed" -lt 2000
echo "drain-deadline: ok"
