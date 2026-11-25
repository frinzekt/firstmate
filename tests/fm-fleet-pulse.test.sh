#!/usr/bin/env bash
# bin/fm-fleet-pulse.sh, the fleet pane's sidecar: the pure parsing and math helpers it
# exposes when sourced, then the whole script over a fixture state directory and a
# fixture transcript root. No Claude Code binary and no real fleet state is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found for the fleet pulse checks"; exit 0; }

PULSE="$ROOT/bin/fm-fleet-pulse.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-pulse)
US=$(printf '\037')
NOW=1800000000

# shellcheck source=bin/fm-fleet-pulse.sh
. "$PULSE"

assert_eq() {  # <actual> <expected> <what>
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

test_parse_status() {
  assert_eq "$(fm_pulse_parse_status 'blocked [at=1792996972]: PR 623 pushed')" "blocked${US}1792996972${US}PR 623 pushed" "status with epoch"
  assert_eq "$(fm_pulse_parse_status 'needs-decision [at=5] [key=pick-one]: A or B?')" "needs-decision${US}5${US}A or B?" "status with key"
  assert_eq "$(fm_pulse_parse_status 'working: no stamp here')" "working${US}${US}no stamp here" "status without epoch keeps an empty field"
  assert_eq "$(fm_pulse_parse_status 'done [at=12x]: bad stamp')" "done${US}${US}bad stamp" "non-numeric epoch is dropped"
  local long out text
  long=$(printf 'x%.0s' $(seq 1 400))
  out=$(fm_pulse_parse_status "paused [at=1]: $long")
  text=${out##*"$US"}
  [ "${#text}" -le "$FM_PULSE_STATUS_MAX" ] || fail "status text is not capped at $FM_PULSE_STATUS_MAX (got ${#text})"
  pass "status lines parse into state, epoch, and capped text"
}

test_parse_busy() {
  assert_eq "$(fm_pulse_parse_busy 'v1 gen=g1 seq=2 state=busy source=claude-hook event=user-prompt-submit ts=1793586608')" "busy${US}1793586608" "busy line"
  assert_eq "$(fm_pulse_parse_busy 'v1 gen=g1 seq=3 state=idle ts=7')" "idle${US}7" "idle line"
  assert_eq "$(fm_pulse_parse_busy 'garbage')" "unknown${US}" "unparseable line"
  pass "busy-state lines parse into busy/idle and an epoch"
}

test_effective_state() {
  assert_eq "$(fm_pulse_effective_state busy 100 blocked 50)" busy "a worker busy since after the block is busy"
  assert_eq "$(fm_pulse_effective_state busy 100 blocked 150)" blocked "a block newer than the busy event wins"
  assert_eq "$(fm_pulse_effective_state idle 100 paused 50)" paused "an idle worker shows its last wait"
  assert_eq "$(fm_pulse_effective_state idle 100 resolved 150)" idle "resolved never wins"
  assert_eq "$(fm_pulse_effective_state busy 100 working 150)" busy "working never wins"
  assert_eq "$(fm_pulse_effective_state unknown '' '' '')" unknown "no records at all"
  pass "a card state is busy/idle unless a newer wait or captain call overrides it"
}

test_window_percent_title() {
  assert_eq "$(fm_pulse_window claude-opus-5-5)" 1000000 "opus runs with a 1M window"
  assert_eq "$(fm_pulse_window claude-sonnet-5-5)" 1000000 "sonnet runs with a 1M window"
  assert_eq "$(fm_pulse_window claude-haiku-5-5)" 200000 "haiku keeps the 200k window"
  assert_eq "$(fm_pulse_window unknown-model)" 200000 "default window"
  assert_eq "$(fm_pulse_window 'claude-haiku-5-5[1m]')" 1000000 "1m variant"
  assert_eq "$(fm_pulse_window claude-haiku-5-5 250000)" 1000000 "tokens past 200k imply the 1M window"
  assert_eq "$(fm_pulse_percent 108000 200000)" 54 "percent"
  assert_eq "$(fm_pulse_percent 300000 200000)" 100 "percent is capped"
  assert_eq "$(fm_pulse_percent '' 200000)" "" "unknown tokens give no percent"
  assert_eq "$(fm_pulse_title 'Fix the parser' fm/x/a a)" "Fix the parser" "ai-title wins"
  assert_eq "$(fm_pulse_title 'Firstmate operational inbox message' fm/flapuz/MLP-1/a a)" "flapuz/MLP-1" "generic title falls back to the branch"
  assert_eq "$(fm_pulse_title '' fm/a a)" "" "branch equal to the id gives nothing"
  assert_eq "$(fm_pulse_transcript_dir /Users/x/orca/ws.v/fm-a "$TMP_ROOT/p")" "$TMP_ROOT/p/-Users-x-orca-ws-v-fm-a" "transcript dir name"
  assert_eq "$(fm_pulse_price claude-opus-5-5)" "4 20 5 0.2" "opus price"
  assert_eq "$(fm_pulse_price claude-sonnet-5-5)" "2 10 2.5 0.2" "sonnet price"
  assert_eq "$(fm_pulse_price claude-haiku-5-5)" "0.1 0.5 0.125 0.01" "haiku price"
  pass "window, percent, title, transcript directory, and price tables"
}

# A transcript with a cut first line (as `tail -c` leaves), a title, a streamed message id
# that repeats, and a final assistant row.
write_transcript() {  # <file>
  {
    printf '%s\n' 'cut-off partial line {"type":'
    printf '%s\n' '{"type":"ai-title","aiTitle":"Build the fleet pane"}'
    printf '%s\n' '{"type":"user","message":{"content":"hi"}}'
    printf '%s\n' '{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
    printf '%s\n' '{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0}}}'
    printf '%s\n' '{"type":"assistant","effort":"high","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":100,"cache_creation_input_tokens":400,"cache_read_input_tokens":108000}}}'
  } >"$1"
}

test_zero_usage_rows() {
  local ctx
  ctx=$(printf '%s\n' \
    '{"type":"assistant","message":{"id":"a","model":"claude-opus-5-5","usage":{"input_tokens":5,"cache_read_input_tokens":777,"cache_creation_input_tokens":0}}}' \
    '{"type":"assistant","message":{"id":"b","model":"<synthetic>","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' |
    fm_pulse_usage_context)
  assert_eq "$(printf '%s' "$ctx" | jq -r .tokens)" 782 "an interrupted turn's all-zero row is not the context reading"
  pass "synthetic and all-zero usage rows never replace the last real context reading"
}

test_usage_math() {
  local file="$TMP_ROOT/t.jsonl" ctx cost
  write_transcript "$file"
  ctx=$(fm_pulse_usage_context <"$file")
  assert_eq "$(printf '%s' "$ctx" | jq -r .tokens)" 108402 "context is input + cache read + cache creation of the last row"
  assert_eq "$(printf '%s' "$ctx" | jq -r .model)" claude-opus-5-5 "model of the last row"
  assert_eq "$(printf '%s' "$ctx" | jq -r .title)" "Build the fleet pane" "ai-title"
  # m1 counts once (its last row): in 10, out 20, cache write 1000; m2: in 2, out 100, write 400, read 108000.
  # (12*15 + 120*75 + 1400*18.75 + 108000*1.5) / 1e6 = 0.197430
  cost=$(fm_pulse_usage_cost 15 75 18.75 1.5 <"$file")
  assert_eq "$cost" 0.1974 "estimated cost counts each message id once"
  assert_eq "$(printf '' | fm_pulse_usage_context)" '{"tokens":null,"model":null,"effort":null,"title":null}' "empty transcript"
  pass "transcript parsing: last-row context, one count per message id, cost from the price table"
}

test_cost_state_is_exact() {
  local dir="$TMP_ROOT/cs" st="$TMP_ROOT/cs-state"
  mkdir -p "$dir/s1/subagents" "$st"
  write_transcript "$dir/s1.jsonl"
  printf '%s\n' '{"type":"cost-state","totalCostUSD":1.25,"modelUsage":{"claude-opus-5-5":{"inputTokens":10,"outputTokens":20,"thinkingTokens":5,"cacheReadInputTokens":1000,"cacheCreationInputTokens":100,"costUSD":1.0},"claude-haiku-5-5":{"inputTokens":1,"outputTokens":2,"cacheReadInputTokens":3,"cacheCreationInputTokens":4,"costUSD":0.25}}}' >>"$dir/s1.jsonl"
  write_transcript "$dir/s1/subagents/agent-a1.jsonl"
  local s
  s=$(fm_pulse_dir_stats "$st" "$dir")
  assert_eq "$(printf '%s' "$s" | jq -r .cost)" 1.25 "cost-state total is used and subagents are not added again"
  assert_eq "$(printf '%s' "$s" | jq -r .exact)" true "cost-state marks the cost exact"
  assert_eq "$(printf '%s' "$s" | jq -c .breakdown)" '{"input":11,"output":22,"cache_read":1003,"cache_write":104}' "token breakdown from cost-state"
  assert_eq "$(printf '%s' "$s" | jq -r '.subagents | length')" 1 "subagents still listed"
  assert_eq "$(printf '%s' "$s" | jq -c '.by_model | map([.model, .cost])')" '[["claude-haiku-5-5",0.25],["claude-opus-5-5",1]]' "spend per model from cost-state"
  assert_eq "$(printf '%s' "$s" | jq -r '[.model, .effort] | join(",")')" "claude-opus-5-5,high" "the main transcript's model and last recorded effort"
  assert_eq "$(printf '%s' "$s" | jq -r '.subagents[0] | [.model, .effort] | join(",")')" "claude-opus-5-5,high" "a subagent row carries its model's effort"
  assert_eq "$(printf '%s' "$(write_transcript "$TMP_ROOT/e.jsonl"; fm_pulse_usage_context <"$TMP_ROOT/e.jsonl")" | jq -r .effort)" high "the context reading carries the last row's effort"
  pass "cost-state gives the exact cost and token breakdown"
}

make_fixture() {  # <state-dir> <projects-dir>
  local state=$1 projects=$2 worktree=/fx/wt/fm-w1
  mkdir -p "$state" "$projects/-fx-wt-fm-w1"
  {
    printf 'worktree=%s\nharness=claude\nkind=ship\nmodel=opus\nbranch=fm/me/JIRA-1/w1\n' "$worktree"
  } >"$state/w1.meta"
  printf 'v1 gen=g seq=1 state=busy source=claude-hook event=x ts=%s\n' "$((NOW - 300))" >"$state/w1.busy-state"
  printf 'paused [at=%s]: waiting\nblocked [at=%s]: stuck on merge\n' "$((NOW - 3600))" "$((NOW - 100))" >"$state/w1.status"
  write_transcript "$projects/-fx-wt-fm-w1/s1.jsonl"
  printf 'worktree=/fx/wt/fm-w2\nharness=pi\nkind=scout\nmodel=gpt\n' >"$state/w2.meta"
  printf 'v1 gen=g seq=1 state=busy source=h event=x ts=%s\n' "$((NOW - 10))" >"$state/w2.busy-state"
  printf 'needs-decision [at=%s]: pick A or B\n' "$((NOW - 5))" >"$state/w2.status"
  : >"$state/w3.meta"
}

test_end_to_end() {
  local state="$TMP_ROOT/e2e/state" projects="$TMP_ROOT/e2e/projects" json before
  make_fixture "$state" "$projects"
  before=$(cd "$TMP_ROOT/e2e" && find . -type f ! -name .fleet-stats-cache -exec cksum {} + | sort)
  json=$(FM_STATE_OVERRIDE="$state" FM_PULSE_PROJECTS_DIR="$projects" FM_PULSE_NOW="$NOW" bash "$PULSE" --stdout) || fail "the sidecar failed on the fixture"
  assert_eq "$(printf '%s' "$json" | jq -r '.workers | map(.id) | join(",")')" "w1,w2,w3" "workers sorted by id"
  assert_eq "$(printf '%s' "$json" | jq -r '.workers[0].state')" blocked "w1: a block newer than its busy event"
  assert_eq "$(printf '%s' "$json" | jq -r '.workers[0].waiting_on_captain')" true "w1 waits on the captain"
  assert_eq "$(printf '%s' "$json" | jq -r '.workers[0].context.pct')" 10 "w1 context percent (opus runs with a 1M window)"
  assert_eq "$(printf '%s' "$json" | jq -r '.workers[0].cost_usd')" 0.031 "w1 estimated cost (opus 5.5 prices)"
  assert_eq "$(printf '%s' "$json" | jq -r '.workers[0].title')" "Build the fleet pane" "w1 title"
  assert_eq "$(printf '%s' "$json" | jq -r '.workers[0].last_event_at')" "$((NOW - 100))" "w1 last event is the newer of busy and status"
  assert_eq "$(printf '%s' "$json" | jq -r '.workers[1].state')" needs-decision "w2 needs a decision"
  assert_eq "$(printf '%s' "$json" | jq -r '.workers[1].cost_usd')" null "a non-Claude worker has no cost guess"
  assert_eq "$(printf '%s' "$json" | jq -r '.workers[1].context.pct')" null "a non-Claude worker has no context guess"
  assert_eq "$(printf '%s' "$json" | jq -r '.workers[2].state')" unknown "an empty meta still lists the worker"
  assert_eq "$(printf '%s' "$json" | jq -c '.counts')" '{"blocked":1,"needs-decision":1,"unknown":1}' "counts by state"
  assert_eq "$(printf '%s' "$json" | jq -r '.total_cost_usd')" 0.031 "total of the estimated costs"
  assert_eq "$(printf '%s' "$json" | jq -r '.estimate')" true "the pulse labels itself an estimate"
  [ "$before" = "$(cd "$TMP_ROOT/e2e" && find . -type f ! -name .fleet-stats-cache -exec cksum {} + | sort)" ] || fail "--stdout changed a fixture file"
  pass "the sidecar summarizes a fixture fleet and changes none of its inputs"
}

# A ledger with finished tasks at several ages, duplicates, a malformed line, an unfinished
# task, and a spend ledger with a repeated incarnation record.
write_ledgers() {  # <state-dir> <data-dir>
  local state=$1 data=$2 day=86400
  mkdir -p "$state" "$data"
  {
    printf '{"v":1,"ts":%s,"event":"task.dispatched","task":"recent","kind":"ship","project":"p","harness":"claude","model":"sonnet"}\n' "$((NOW - 3 * day - 5000))"
    printf '{"v":1,"ts":%s,"event":"task.pr_ready","task":"recent","pr":"https://x/1"}\n' "$((NOW - 3 * day - 2000))"
    printf '{"v":1,"ts":%s,"event":"task.merged","task":"recent","via":"pr","pr":"https://x/1"}\n' "$((NOW - 3 * day - 100))"
    printf '{"v":1,"ts":%s,"event":"task.merged","task":"recent","via":"pr","pr":"https://x/1"}\n' "$((NOW - 3 * day - 100))"
    printf '{"v":1,"ts":%s,"event":"task.cleaned_up","task":"recent"}\n' "$((NOW - 3 * day))"
    printf 'not json at all\n'
    printf '{"v":1,"ts":%s,"event":"task.dispatched","task":"month","kind":"scout"}\n' "$((NOW - 30 * day - 600))"
    printf '{"v":1,"ts":%s,"event":"task.cleaned_up","task":"month"}\n' "$((NOW - 30 * day))"
    printf '{"v":1,"ts":%s,"event":"task.merged","task":"ancient","via":"local"}\n' "$((NOW - 70 * day))"
    printf '{"v":1,"ts":%s,"event":"task.dispatched","task":"declined","kind":"ship"}\n' "$((NOW - 40 * day - 900))"
    printf '{"v":1,"ts":%s,"event":"task.pr_ready","task":"declined","pr":"https://bitbucket.org/a/r/pull-requests/12"}\n' "$((NOW - 40 * day - 500))"
    printf '{"v":1,"ts":%s,"event":"task.closed","task":"declined","via":"pr","pr":"https://bitbucket.org/a/r/pull-requests/12"}\n' "$((NOW - 40 * day - 100))"
    printf '{"v":1,"ts":%s,"event":"task.cleaned_up","task":"declined","pr":"https://bitbucket.org/a/r/pull-requests/12"}\n' "$((NOW - 40 * day))"
    printf '{"v":1,"ts":%s,"event":"task.dispatched","task":"live","kind":"ship"}\n' "$((NOW - 100))"
    printf '{"v":1,"ts":%s,"event":"task.status","task":"live","state":"working","key":null,"text":" hi"}\n' "$((NOW - 50))"
  } >"$state/fleet-ledger.jsonl"
  {
    printf '{"task":"recent","spawn_gen":"s1","recorded_at":"2026-11-01T10:00:00Z","total":{"input_tokens":{"total":1000,"unknown":0},"output_tokens":{"total":500,"unknown":1}}}\n'
    printf '{"task":"recent","spawn_gen":"s1","recorded_at":"2026-11-01T10:00:01Z","total":{"input_tokens":{"total":1000,"unknown":0},"output_tokens":{"total":500,"unknown":1}}}\n'
    printf '{"task":"recent","spawn_gen":"s2","recorded_at":"2026-11-01T11:00:00Z","total":{"input_tokens":{"total":200,"unknown":0},"output_tokens":{"total":100,"unknown":0}}}\n'
    printf 'garbage\n'
  } >"$data/pipeline-spend.jsonl"
}

test_history() {
  local state="$TMP_ROOT/h/state" data="$TMP_ROOT/h/data" h
  write_ledgers "$state" "$data"
  h=$(fm_pulse_history "$state/fleet-ledger.jsonl" "$data/pipeline-spend.jsonl" "$NOW") || fail "history failed"
  assert_eq "$(printf '%s' "$h" | jq -r '.rows | map(.task) | join(",")')" "recent,month,declined" "finished tasks within 60 days, newest first, unfinished and ancient left out"
  assert_eq "$(printf '%s' "$h" | jq -r '.rows[0] | [.outcome, .via, .duration_s] | join(",")')" "merged,pr,5000" "outcome, route, and duration of the duplicate-recorded task"
  assert_eq "$(printf '%s' "$h" | jq -r '.rows[0].model')" sonnet "history keeps the dispatched model from the ledger as a fallback"
  assert_eq "$(printf '%s' "$h" | jq -r '.rows[1].model')" null "no recorded model stays null"
  assert_eq "$(printf '%s' "$h" | jq -r '.rows[0] | [.kind, .pr] | join(",")')" "ship,https://x/1" "kind and PR link from the ledger records"
  assert_eq "$(printf '%s' "$h" | jq -r '.rows[2] | [.outcome, .pr] | join(",")')" "closed,https://bitbucket.org/a/r/pull-requests/12" "a declined PR is outcome closed with its link"
  assert_eq "$(printf '%s' "$h" | jq -r '.rows[1] | [.kind, .pr] | join(",")')" "scout," "a task with no PR record has a null pr"
  assert_eq "$(printf '%s' "$h" | jq -r '.rows[0].spend_tokens')" 1800 "spend counts each incarnation once and sums incarnations (in+out)"
  assert_eq "$(printf '%s' "$h" | jq -r '.rows[0].spend_unknown')" 1 "unknown invocations make spend a lower bound"
  assert_eq "$(printf '%s' "$h" | jq -r '.rows[1] | [.outcome, .via, .spend_tokens] | join(",")')" "cleaned_up,,"  "a task with no merge and no spend"
  assert_eq "$(printf '%s' "$h" | jq -r '.ledger_since')" "$((NOW - 70 * 86400))" "the ledger's first record time"
  : >"$state/fleet-ledger.jsonl"
  assert_eq "$(fm_pulse_history "$state/fleet-ledger.jsonl" "$data/pipeline-spend.jsonl" "$NOW")" '{"ledger_since":null,"window_days":60,"rows":[]}' "an empty ledger gives an empty history"
  assert_eq "$(fm_pulse_history "$TMP_ROOT/none.jsonl" "$TMP_ROOT/none2.jsonl" "$NOW")" '{"ledger_since":null,"window_days":60,"rows":[]}' "absent ledgers give an empty history"
  pass "history: finished tasks inside 60 days joined with spend, duplicates and junk tolerated, empty and absent ledgers empty"
}

test_history_in_pulse() {
  local state="$TMP_ROOT/hp/state" data="$TMP_ROOT/hp/data" projects="$TMP_ROOT/hp/projects"
  write_ledgers "$state" "$data"
  mkdir -p "$projects"
  assert_eq "$(FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_PULSE_PROJECTS_DIR="$projects" FM_PULSE_NOW="$NOW" bash "$PULSE" --stdout | jq -r '.history.rows | length')" 3 "the pulse carries the history"
  pass "the pulse file carries the history section"
}

test_atomic_write() {
  local state="$TMP_ROOT/w/state" projects="$TMP_ROOT/w/projects"
  make_fixture "$state" "$projects"
  FM_STATE_OVERRIDE="$state" FM_PULSE_PROJECTS_DIR="$projects" FM_PULSE_NOW="$NOW" bash "$PULSE" --once || fail "--once failed"
  jq -e '.version == 1 and (.workers | length) == 3' "$state/.fleet-pulse.json" >/dev/null || fail "pulse file is not the expected JSON"
  [ -z "$(find "$state" -name '.fleet-pulse.json.*')" ] || fail "a temporary pulse file was left behind"
  FM_STATE_OVERRIDE="$state" FM_PULSE_PROJECTS_DIR="$projects" FM_PULSE_NOW="$((NOW + 5))" bash "$PULSE" || fail "second run failed"
  assert_eq "$(jq -r .generated_at "$state/.fleet-pulse.json")" "$((NOW + 5))" "a second run replaces the file"
  assert_eq "$(FM_STATE_OVERRIDE="$TMP_ROOT/none" bash "$PULSE" 2>&1 | head -n 1)" "fm-fleet-pulse: no state directory at $TMP_ROOT/none" "a missing state directory is reported"
  bash "$PULSE" --bogus >/dev/null 2>&1 && fail "an unknown flag was accepted"
  pass "the pulse file is replaced atomically, and bad input is refused"
}

test_bash32() {
  [ -x /bin/bash ] || { pass "no /bin/bash to check"; return 0; }
  local state="$TMP_ROOT/b32/state" projects="$TMP_ROOT/b32/projects" out
  make_fixture "$state" "$projects"
  out=$(FM_STATE_OVERRIDE="$state" FM_PULSE_PROJECTS_DIR="$projects" FM_PULSE_NOW="$NOW" /bin/bash "$PULSE" --stdout) || fail "the sidecar failed under /bin/bash"
  assert_eq "$(printf '%s' "$out" | jq -r '.workers[0].state')" blocked "the system bash reads the same fixture"
  pass "the sidecar runs under the system /bin/bash"
}

fm_test_run test_parse_status test_parse_busy test_effective_state test_window_percent_title test_usage_math test_cost_state_is_exact test_zero_usage_rows test_end_to_end test_history test_history_in_pulse test_atomic_write test_bash32
