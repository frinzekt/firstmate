#!/usr/bin/env bash
# bin/fm-ledger-prune.sh: drops records older than N days from state/fleet-ledger.jsonl and
# data/pipeline-spend.jsonl only, dry run changes nothing, and no other file is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found for the ledger prune checks"; exit 0; }

PRUNE="$ROOT/bin/fm-ledger-prune.sh"
TMP_ROOT=$(fm_test_tmproot fm-ledger-prune)
NOW=1800000000
DAY=86400

assert_eq() {  # <actual> <expected> <what>
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

# make_home <dir>: a home with both ledgers and bystander files that must never change.
make_home() {
  local h=$1
  mkdir -p "$h/state" "$h/data/some-task" "$h/data/done-archive"
  {
    printf '{"v":1,"ts":%s,"event":"task.cleaned_up","task":"old"}\n' "$((NOW - 61 * DAY))"
    printf '{"v":1,"ts":%s,"event":"task.cleaned_up","task":"edge"}\n' "$((NOW - 60 * DAY))"
    printf '{"v":1,"ts":%s,"event":"task.cleaned_up","task":"fresh"}\n' "$((NOW - 1 * DAY))"
    printf 'not json, kept\n'
    printf '{"v":1,"event":"task.cleaned_up","task":"no-ts"}\n'
    printf '{"v":1,"ts":"soon","event":"task.cleaned_up","task":"bad-ts"}\n'
  } >"$h/state/fleet-ledger.jsonl"
  {
    printf '{"task":"old","recorded_at":"2026-01-01T00:00:00Z"}\n'
    printf '{"task":"old-frac","recorded_at":"2026-01-02T03:04:05.678Z"}\n'
    printf '{"task":"fresh","recorded_at":"%s"}\n' "$(date -u -r "$((NOW - 2 * DAY))" +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"task":"no-time"}\n'
  } >"$h/data/pipeline-spend.jsonl"
  printf 'report\n' >"$h/data/some-task/report.md"
  printf 'brief\n' >"$h/data/some-task/brief.md"
  printf 'backlog\n' >"$h/data/backlog.md"
  printf 'archived\n' >"$h/data/done-archive/old.md"
  printf 'status old\n' >"$h/state/some-task.status"
  : >"$h/state/other.jsonl"
}

# Everything but the two ledgers, as a checksum list.
bystanders() {  # <home>
  (cd "$1" && find . -type f ! -name fleet-ledger.jsonl ! -name pipeline-spend.jsonl -exec cksum {} + | sort)
}

run_prune() {  # <home> <args...>
  local h=$1
  shift
  FM_HOME="$h" FM_PRUNE_NOW="$NOW" bash "$PRUNE" "$@"
}

test_dry_run() {
  local h="$TMP_ROOT/dry" before out
  make_home "$h"
  before=$(cd "$h" && find . -type f -exec cksum {} + | sort)
  out=$(run_prune "$h" --dry-run) || fail "dry run failed"
  case "$out" in *"would drop 1 of 6 records, keep 5"*) : ;; *) printf '%s\n' "$out" >&2; fail "dry run did not report the ledger's drop count" ;; esac
  case "$out" in *"would drop 2 of 4 records, keep 2"*) : ;; *) printf '%s\n' "$out" >&2; fail "dry run did not report the spend drop count" ;; esac
  [ "$before" = "$(cd "$h" && find . -type f -exec cksum {} + | sort)" ] || fail "dry run changed a file"
  [ -z "$(find "$h" -name '*.prune.*')" ] || fail "dry run left a temporary file"
  pass "--dry-run reports counts and changes no file"
}

test_real_prune() {
  local h="$TMP_ROOT/real" others out
  make_home "$h"
  others=$(bystanders "$h")
  out=$(run_prune "$h") || fail "prune failed"
  case "$out" in *"dropped 1 of 6 records, kept 5"*) : ;; *) printf '%s\n' "$out" >&2; fail "prune did not report the ledger drop" ;; esac
  assert_eq "$(jq -R -r 'fromjson? | .task // empty' "$h/state/fleet-ledger.jsonl" | tr '\n' ,)" "edge,fresh,no-ts,bad-ts," "only the record older than 60 days is dropped, and a record exactly at the cutoff stays"
  grep -qx 'not json, kept' "$h/state/fleet-ledger.jsonl" || fail "a non-JSON line was dropped"
  assert_eq "$(jq -r '.task' "$h/data/pipeline-spend.jsonl" | tr '\n' ,)" "fresh,no-time," "spend records older than 60 days are dropped, fractional seconds included"
  assert_eq "$(bystanders "$h")" "$others" "no other file changed"
  [ -z "$(find "$h" -name '*.prune.*')" ] || fail "a temporary file was left behind"
  out=$(run_prune "$h") || fail "second prune failed"
  case "$out" in *"dropped 0 of 5 records"*) : ;; *) printf '%s\n' "$out" >&2; fail "a second prune is not a no-op" ;; esac
  pass "prune drops only records older than the window from the two ledgers and leaves every other file alone"
}

test_days_option() {
  local h="$TMP_ROOT/days" out
  make_home "$h"
  out=$(run_prune "$h" --days 2) || fail "prune --days failed"
  assert_eq "$(jq -R -r 'fromjson? | .task // empty' "$h/state/fleet-ledger.jsonl" | tr '\n' ,)" "fresh,no-ts,bad-ts," "--days 2 keeps only the last two days"
  pass "--days narrows the window"
}

test_absent_and_bad_input() {
  local h="$TMP_ROOT/absent" out
  mkdir -p "$h/state" "$h/data"
  out=$(run_prune "$h") || fail "prune failed on a home with no ledgers"
  case "$out" in *"absent, skipped"*) : ;; *) fail "absent ledgers were not skipped: $out" ;; esac
  [ -z "$(find "$h" -type f)" ] || fail "prune created a file where there was none"
  run_prune "$h" --days 0 >/dev/null 2>&1 && fail "--days 0 was accepted"
  run_prune "$h" --days abc >/dev/null 2>&1 && fail "--days abc was accepted"
  run_prune "$h" --nope >/dev/null 2>&1 && fail "an unknown flag was accepted"
  : >"$h/state/fleet-ledger.jsonl"
  run_prune "$h" >/dev/null || fail "an empty ledger failed"
  pass "absent and empty ledgers are fine, and bad arguments are refused"
}

test_bash32() {
  [ -x /bin/bash ] || { pass "no /bin/bash to check"; return 0; }
  local h="$TMP_ROOT/b32" out
  make_home "$h"
  out=$(FM_HOME="$h" FM_PRUNE_NOW="$NOW" /bin/bash "$PRUNE") || fail "prune failed under /bin/bash"
  case "$out" in *"dropped 1 of 6"*) : ;; *) fail "unexpected /bin/bash output: $out" ;; esac
  pass "prune runs under the system /bin/bash"
}

fm_test_run test_dry_run test_real_prune test_days_option test_absent_and_bad_input test_bash32
