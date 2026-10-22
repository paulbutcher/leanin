#!/usr/bin/env bash
# The `Std`-shaped layer's `Date` value is an IMF-fixdate, checked at fixed instants against `date -u`.
#
#   nix develop -c bash tests/std-date.sh
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(lake exe stdEcho --date-check)
echo "$out"
grep -q '^dateCheck|ok=true$' <<<"$out"
echo "std-date: ok"
