#!/usr/bin/env bash
#
# Behaviour check for timeout cancellation: a computation whose `withTimeout` deadline wins does not resume.
#
# The check drives the public boundary — the `controls` executable — and asserts on the record that boundary
# produced. Nothing here calls a private function: the boundary is the executable's stdout.
#
# A failure before the scenario's own assertion — the executable did not run, the library did not build, the
# record is absent, repeated or malformed, or the detector's own affirmative control does not hold — is a setup
# error with exit 2. A scenario assertion that does not hold exits 1 with its own text, so the two are never
# confused. The watchdog below only bounds the invocation so that a wait which never returns cannot hang the
# command forever; it reads no clock towards any relation and a bound expiry is a defect of the invocation.
#
# Usage, from the repository root:
#   nix develop -c bash tests/timeout-cancel-contract.sh TC1

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || {
  printf 'setup error: cannot enter %s\n' "$repo_root" >&2
  exit 2
}

# Seconds the invocation is allowed before it is bounded. Generous: it bounds a hang, it does not budget a run.
watchdog_seconds="${LEANIN_WATCHDOG:-300}"

# The instant the fixture makes the loser sleep to. The run is asserted to have advanced at least this far, so
# the loser's own wake was reached before the record was read.
readonly loser_wake_instant=30

fail() {
  printf '%s\n' "$1" >&2
  shift
  for detail in "$@"; do printf '  %s\n' "$detail" >&2; done
  exit 1
}

setup_error() {
  printf 'setup error: %s\n' "$1" >&2
  shift
  for detail in "$@"; do printf '  %s\n' "$detail" >&2; done
  exit 2
}

# bounded <command...> — run the invocation under the watchdog.
bounded() {
  timeout "$watchdog_seconds" "$@"
}

# check_status <check> <status> <command...> — a nonzero status is a defect of the invocation, never an
# assertion. 124 is the watchdog bounding it: a wait that never returned produced no record to assert on, so it
# is reported as a defect, naming the check whose invocation was bounded, rather than as that check's result.
check_status() {
  local check="$1" status="$2"
  shift 2
  [ "$status" -eq 0 ] && return 0
  if [ "$status" -eq 124 ]; then
    setup_error "$check: the invocation did not finish within ${watchdog_seconds}s — a bounded wait, not a check result" \
      "invocation: $*" \
      "no record was read, so nothing is asserted either way"
  fi
  setup_error "$check: invocation exited $status" "invocation: $*"
}

# The control executable prints an affirmative baseline header before any observation.
require_header() {
  case "$1" in
  *"controls for the bridge axioms"*) : ;;
  *) setup_error "the control executable did not print its baseline header" \
    "stdout began: $(printf '%s' "$1" | head -c 200)" ;;
  esac
}

# tokens <record> — the |-separated fields of a record, one per line, the final line newline terminated so a
# `read` loop delivers the last field instead of stopping at EOF without it.
tokens() {
  printf '%s\n' "$1" | tr '|' '\n'
}

# field <key> <record> — print the value of the record's single `key=` field. Exits nonzero when the key is
# absent, repeated or empty, so a value is never bound from a neighbouring field, from a repeat of the key, or
# from the tail of a longer one.
field() {
  local key="$1" rec="$2" tok n=0 val=""
  while IFS= read -r tok; do
    case "$tok" in
    "$key="*)
      n=$((n + 1))
      val="${tok#"$key="}"
      ;;
    esac
  done < <(tokens "$rec")
  [ "$n" -eq 1 ] && [ -n "$val" ] || return 1
  printf '%s' "$val"
}

# bound_field <variable> <key> <record> <what> — set <variable> to the record's single nonempty `key` value, or
# report a setup error naming <what>. It writes through `printf -v` rather than stdout so that a setup error
# here exits this shell instead of a command-substitution subshell.
bound_field() {
  local var="$1" key="$2" rec="$3" what="$4" val
  val="$(field "$key" "$rec")" ||
    setup_error "$what has no single nonempty $key field" "record: [$rec]"
  printf -v "$var" '%s' "$val"
}

# record_is <record> <field>... — true when <record> splits into exactly the named `key=value` fields, in that
# order, each nonempty and appearing once. An extra, missing, empty, reordered or duplicated field is rejected,
# so a near miss that keeps the expected tokens cannot pass.
record_is() {
  local rec="$1"
  shift
  local -a want=("$@")
  local tok n=0 k
  while IFS= read -r tok; do
    k="${want[$n]:-}"
    [ -n "$k" ] || return 1
    case "$tok" in
    "$k="?*) : ;;
    *) return 1 ;;
    esac
    n=$((n + 1))
  done < <(tokens "$rec")
  [ "$n" -eq "${#want[@]}" ]
}

# loser_ok <record> — the timeout-loser observations as a detector, so its own control reuses it rather than a
# lookalike: the deadline won, the same recorder that saw the loser start saw no effect after its own sleep,
# the harness instant advanced at least to that wake, and the detector's affirmative control actually observed
# the marker the same recorder and the same containment test produce. Every value is taken from its own named
# field.
loser_ok() {
  local rec="$1" outcome started after advanced detected
  outcome="$(field outcome "$rec")" || return 1
  started="$(field start "$rec")" || return 1
  after="$(field after "$rec")" || return 1
  advanced="$(field advanced "$rec")" || return 1
  detected="$(field afterDetectedWhenPresent "$rec")" || return 1
  [ "$outcome" = "none" ] || return 1
  [ "$started" = "true" ] || return 1
  [ "$after" = "false" ] || return 1
  case "$advanced" in '' | *[!0-9]*) return 1 ;; esac
  [ "$advanced" -ge "$loser_wake_instant" ] || return 1
  [ "$detected" = "true" ]
}

# --- TC1 — a timed-out computation never resumes afterwards ————————————————————————————————————————————————
check_tc1() {
  local out status line
  local outcome started after advanced detected
  local near
  local -a records=()

  out="$(bounded lake exe controls --runtime-time-loser)"
  status=$?
  check_status TC1 "$status" "lake exe controls --runtime-time-loser"
  require_header "$out"

  mapfile -t records < <(grep '^timeoutLoser|' <<<"$out" || true)
  [ "${#records[@]}" -eq 1 ] ||
    setup_error "TC1: the timeout-loser record is missing or repeated" \
      "expected exactly one timeoutLoser| record from --runtime-time-loser, saw ${#records[@]}" \
      "an absent dedicated mode is a setup failure, not a scenario result"
  line="${records[0]}"

  record_is "${line#timeoutLoser|}" outcome start after advanced afterDetectedWhenPresent ||
    setup_error "TC1: the timeout-loser record is not the fixture's shape" \
      "expected exactly outcome/start/after/advanced/afterDetectedWhenPresent with nonempty values: [$line]"

  # The detector's own control, from the record syntax and the expectation alone. The affirmative-control
  # field is part of the detector, so a record where it is false or absent is rejected here as well.
  loser_ok "outcome=none|start=true|after=false|advanced=${loser_wake_instant}|afterDetectedWhenPresent=true" ||
    setup_error "TC1: the timeout-loser detector rejected a well-formed record" \
      "the detector's own control, not the TC1 Then"
  for near in \
    'outcome=none|start=true|after=true|advanced=50|afterDetectedWhenPresent=true' \
    'outcome=none|start=false|after=false|advanced=50|afterDetectedWhenPresent=true' \
    'outcome=some|start=true|after=false|advanced=50|afterDetectedWhenPresent=true' \
    "outcome=none|start=true|after=false|advanced=$((loser_wake_instant - 1))|afterDetectedWhenPresent=true" \
    'outcome=none|start=true|after=false|advanced=50|afterDetectedWhenPresent=true|after=false' \
    'outcome=none|start=true|after=false|afterDetectedWhenPresent=true' \
    'outcome=none|start=true|after=false|advanced=50|afterDetectedWhenPresent=false' \
    'outcome=none|start=true|after=false|advanced=50'; do
    if loser_ok "$near"; then
      setup_error "TC1: the timeout-loser detector accepted a near miss" \
        "record: [$near]" \
        "the detector's own control, not the TC1 Then"
    fi
  done
  printf 'TC1 control: rejected a loser that resumed, a missing start, a computation that won, an instant short of the wake, a repeated field, a missing field, a false affirmative control and a missing affirmative control\n'

  bound_field outcome outcome "$line" "TC1 Then"
  bound_field started start "$line" "TC1 Then"
  bound_field after after "$line" "TC1 Then"
  bound_field advanced advanced "$line" "TC1 Then"
  bound_field detected afterDetectedWhenPresent "$line" "TC1 Then"

  # The affirmative control is a precondition of reading the absence, so its failure is a setup error: the
  # detector could not see a marker that was actually appended, which says nothing about the loser.
  [ "$detected" = "true" ] ||
    setup_error "TC1: the affirmative control did not observe the recorder's after marker" \
      "afterDetectedWhenPresent=$detected (expected true: the same action, the same recorder and the same containment test, read while the marker was present)" \
      "a false affirmative control is a fixture or control setup failure, not TC1's Then"

  loser_ok "${line#timeoutLoser|}" ||
    fail "TC1 Then: the computation whose deadline won was not stopped before the run advanced past its wake" \
      "outcome=$outcome (expected none: this race's own result)" \
      "start=$started (expected true: the same recorder must see the loser start)" \
      "after=$after (expected false: no effect recorded after the deadline won)" \
      "advanced=$advanced (expected at least $loser_wake_instant, the instant the loser sleeps to)" \
      "afterDetectedWhenPresent=$detected (expected true: the affirmative control's own reading)"

  printf 'TC1 ok: outcome=%s start=%s after=%s advanced=%s (>=%s) afterDetectedWhenPresent=%s — the deadline won and the loser recorded nothing after its wake\n' \
    "$outcome" "$started" "$after" "$advanced" "$loser_wake_instant" "$detected"
}

case "${1:-}" in
TC1) check_tc1 ;;
*)
  printf 'usage: bash tests/timeout-cancel-contract.sh TC1\n' >&2
  exit 2
  ;;
esac
