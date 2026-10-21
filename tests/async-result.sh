#!/usr/bin/env bash
# async-result.sh — `async def … : T` delivers a result through the public EAsync entry.
#
# One machine returns immediately, one returns after a timer; both must resolve with their declared result.
set -uo pipefail
cd "$(dirname "$0")/.."
lake build asyncResult >/dev/null || { echo "async-result: build failed" >&2; exit 1; }
out="$(timeout 20 ./.lake/build/bin/asyncResult 2>&1)" || { echo "$out"; echo "async-result: FAIL"; exit 1; }
grep -q "immediate and post-suspension returns delivered" <<<"$out" || { echo "$out"; echo "async-result: FAIL"; exit 1; }
echo "async-result: all checks passed"
