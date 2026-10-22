#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(nix develop -c lake exe vmScope)
echo "$out"
grep -q 'scope=true' <<<"$out"
grep -q 'pure=1' <<<"$out"
grep -q 'throw=1' <<<"$out"
grep -q 'abort=1' <<<"$out"
grep -q 'finalizerFailure=1' <<<"$out"
grep -q 'ok=true' <<<"$out"
echo "vm-scope: ok"
