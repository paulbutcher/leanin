#!/usr/bin/env bash
# A stock Std.Http.Server.Handler runs through LeanIn's buffered adapter.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(nix develop -c lake exe compatProbe)
echo "$out"
grep -q 'status=200' <<<"$out"
grep -q 'body=hello' <<<"$out"
grep -q 'x-stock=true' <<<"$out"
grep -q 'ok=true' <<<"$out"
echo "compat-handler: ok"
