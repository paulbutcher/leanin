#!/usr/bin/env bash
# Shared-spawned work must land on more than one carrier.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(nix develop -c lake exe multiCarrier)
echo "$out"
grep -q 'tasks=64' <<<"$out"
carriers=$(sed -n 's/.*carriers=\([0-9]*\).*/\1/p' <<<"$out")
test -n "$carriers" && test "$carriers" -ge 2
echo "multi-carrier: ok"
