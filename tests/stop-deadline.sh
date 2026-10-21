#!/usr/bin/env bash
# A scoped 60 s sleep must be aborted by `Runtime.stopWithDeadline`, not awaited.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(nix develop -c lake exe stopDeadline)
echo "$out"
grep -q 'aborted=yes' <<<"$out"
elapsed=$(sed -n 's/.*elapsedMs=\([0-9]*\).*/\1/p' <<<"$out")
test -n "$elapsed" && test "$elapsed" -lt 2000
echo "stop-deadline: ok"
