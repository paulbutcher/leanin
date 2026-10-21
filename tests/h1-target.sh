#!/usr/bin/env bash
# The H1 head exposes decoded path and query views, rejecting malformed escapes.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(nix develop -c lake exe h1Target)
echo "$out"
grep -q 'path=/a b' <<<"$out"
grep -q 'query=x=1 y&z=/' <<<"$out"
grep -q 'ok=true' <<<"$out"
echo "h1-target: ok"
