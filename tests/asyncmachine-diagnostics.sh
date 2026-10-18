#!/usr/bin/env bash
# asyncmachine-diagnostics.sh — the macro's named diagnostics, and the shapes they reject or accept.
# Run: nix develop -c bash tests/asyncmachine-diagnostics.sh
set -uo pipefail
cd "$(dirname "$0")/.."
export LEAN_PATH=.lake/build/lib/lean
ok=1

expect_error() { # <file> <named fragment>
  local out
  out="$(lean "tests/asyncmachine-diagnostics/$1" 2>&1)" && {
    echo "diag: $1 elaborated; expected rejection mentioning [$2]" >&2; ok=0; return; }
  grep -qF "$2" <<<"$out" || {
    echo "diag: $1 rejected but without [$2]; got:" >&2; echo "$out" >&2; ok=0; }
}

expect_ok() { # <file>
  local out
  out="$(lean "tests/asyncmachine-diagnostics/$1" 2>&1)" || {
    echo "diag: $1 rejected; expected it to elaborate:" >&2; echo "$out" >&2; ok=0; }
}

expect_error unascribed-field.lean 'cannot determine the type of state field `mystery`'
expect_error destructuring-let.lean 'destructuring `let` is not supported'
expect_ok    unthreaded-param.lean

[ "$ok" = 1 ] && echo "asyncmachine-diagnostics: all checks passed" || echo "asyncmachine-diagnostics: FAILED" >&2
[ "$ok" = 1 ]
