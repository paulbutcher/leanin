#!/usr/bin/env bash
# A user-triggered scope cancellation must abort a parked sleep immediately and run cleanup exactly once.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(nix develop -c lake exe scopeCancel)
echo "$out"
grep -q 'aborted=true' <<<"$out"
grep -q 'exits=1' <<<"$out"
grep -q 'exitsAfterRepeat=1' <<<"$out"
grep -q 'childAborted=true' <<<"$out"
grep -q 'childExits=1' <<<"$out"
elapsed=$(sed -n 's/.*elapsedMs=\([0-9]*\).*/\1/p' <<<"$out")
test -n "$elapsed" && test "$elapsed" -lt 200
echo "scope-cancel: ok"
