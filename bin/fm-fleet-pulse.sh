#!/usr/bin/env bash
# fm-fleet-pulse.sh - fleet pulse sidecar for the firstmate-fleet Claude Code mod.
#
# Reads this home's worker records and writes one small JSON file the mod polls:
#   state/<id>.meta         worker identity (kind, harness, model, worktree, branch)
#   state/<id>.busy-state   hook-fed busy/idle line (never a pane scrape)
#   state/<id>.status       append-only status log (last line = last event)
#   ~/.claude/projects/<worktree path, / and . -> ->/<session>.jsonl
#                           Claude workers only: last assistant usage row -> context,
#                           all assistant usage rows -> estimated cost
# It is strictly read-only toward workers, projects, and panes; its only write is the
# pulse file, replaced atomically (temp file in the same directory, then mv).
#
# usage: fm-fleet-pulse.sh [--once | --loop [SECONDS]] [--stdout] [--help]
#   --once      write one pulse and exit (default)
#   --loop N    write a pulse every N seconds (default 5) until interrupted
#   --stdout    print the pulse JSON instead of writing the file
# Environment: FM_HOME (home root; default: the checkout this script lives in),
#   FM_STATE_OVERRIDE (state dir), FM_DATA_OVERRIDE (data dir), FM_PULSE_PROJECTS_DIR (transcript root; default
#   ~/.claude/projects), FM_PULSE_NOW (epoch override for tests).
#
# Output: state/.fleet-pulse.json (schema below). Context % is an ESTIMATE; cost is Claude Code's own cost-state record when the transcript has one (cost_estimate=false), else an estimate: the
# model window and price come from the small tables in this file, and the transcript
# carries no cost field. A worker on another harness, or one with no transcript yet,
# reports null context and cost rather than a guess.
#   { version, generated_at, history, workers: [ { id, kind, harness, model, effort, title, state,
#       busy, waiting_on_captain, last_status, last_status_at, last_event_at,
#       context: { tokens, window, pct, estimate }, cost_usd, cost_estimate } ],
#     counts: { <state>: n }, total_cost_usd, estimate: true }
#   history: { ledger_since, window_days, rows: [ { task, outcome, via, dispatched_at,
#     ended_at, duration_s, spend_tokens, spend_unknown, model, effort, kind, pr, by_model } ] } - finished tasks of the last
#     60 days (the mod filters to 14 or 60), newest first, at most 200. Built from
#     state/fleet-ledger.jsonl (task.dispatched/pr_ready/merged/cleaned_up) joined with
#     data/pipeline-spend.jsonl (no-mistakes tokens in+out; spend_unknown > 0 means the
#     total is a lower bound). Either file may be absent, empty, or hold duplicates and
#     malformed lines; history is then empty or partial, never an error.
# Remote secondmates and non-Claude transcripts are out of scope for v1.
#
# Sourcing this file defines the pure helpers (fm_pulse_*) without running anything,
# so tests/fm-fleet-pulse.test.sh exercises the parsing and math directly.

# Longest status text kept in the pulse; the mod cuts it again to fit its card.
FM_PULSE_STATUS_MAX=${FM_PULSE_STATUS_MAX:-160}
# Transcripts larger than this are not scanned for cost (context still reads the tail).
FM_PULSE_COST_MAX_BYTES=${FM_PULSE_COST_MAX_BYTES:-40000000}
# How much of a transcript's end is read for the last usage row and title.
FM_PULSE_TAIL_BYTES=${FM_PULSE_TAIL_BYTES:-400000}

# fm_pulse_meta_get <meta-file> <key>: the value of the last KEY=value line, or nothing.
fm_pulse_meta_get() {
  [ -f "$1" ] || return 0
  grep -E "^$2=" "$1" 2>/dev/null | tail -n 1 | sed -e "s/^$2=//"
}

# fm_pulse_parse_status <line>: "<state>US<epoch|>US<text>" (US = the 0x1f unit separator, which `read` keeps empty
# fields across, unlike tab) for one status-log line, for example
# `blocked [at=1792996972]: PR open` -> `blocked`, `1792996972`, `PR open`.
# The state is the leading word; the epoch is empty when the line carries no [at=N].
fm_pulse_parse_status() {
  local line=$1 word rest epoch="" text
  word=${line%%[[:space:]]*}
  word=${word%:}
  rest=${line#"$word"}
  case "$rest" in
    *"[at="*)
      epoch=${rest#*\[at=}
      epoch=${epoch%%[]\ ]*}
      case "$epoch" in *[!0-9]*) epoch="" ;; esac
      ;;
  esac
  text=$(printf '%s' "$rest" | sed -e 's/\[[a-z]*=[^]]*\]//g' -e 's/^[[:space:]]*:[[:space:]]*//' -e 's/^[[:space:]]*//' | tr -c '[:print:]' ' ' | tr -s ' ')
  text=${text# }
  text=${text% }
  if [ "${#text}" -gt "$FM_PULSE_STATUS_MAX" ]; then
    text="${text:0:$((FM_PULSE_STATUS_MAX - 1))}…"
  fi
  printf '%s\037%s\037%s\n' "$word" "$epoch" "$text"
}

# fm_pulse_parse_busy <line>: "<busy|idle|unknown>US<epoch|>" (US = 0x1f) from a busy-state line like
# `v1 gen=g1 seq=2 state=busy source=claude-hook event=user-prompt-submit ts=1793586608`.
fm_pulse_parse_busy() {
  local line=$1 state="" ts="" field
  for field in $line; do
    case "$field" in
      state=*) state=${field#state=} ;;
      ts=*) ts=${field#ts=} ;;
    esac
  done
  case "$state" in busy|idle) ;; *) state=unknown ;; esac
  case "$ts" in *[!0-9]*) ts="" ;; esac
  printf '%s\037%s\n' "$state" "$ts"
}

# fm_pulse_effective_state <busy> <busy_ts> <status_word> <status_ts>
# The one word a card shows. A needs-decision, blocked, failed, done, or paused status
# wins only when it is not older than the busy-state event (a worker that has resumed
# since is busy, not blocked); otherwise busy/idle. `resolved` and `working` never win.
fm_pulse_effective_state() {
  local busy=$1 busy_ts=${2:-0} word=$3 ts=${4:-0}
  [ -n "$busy_ts" ] || busy_ts=0
  [ -n "$ts" ] || ts=0
  case "$word" in
    needs-decision | blocked | failed | done | paused)
      if [ "$busy" != busy ] || [ "$ts" -ge "$busy_ts" ]; then
        printf '%s\n' "$word"
        return 0
      fi
      ;;
  esac
  case "$busy" in busy | idle) printf '%s\n' "$busy" ;; *) printf 'unknown\n' ;; esac
}

# fm_pulse_transcript_dir <worktree> <projects-root>: Claude Code's project directory for
# a worktree, its path with every `/` and `.` turned into `-`.
fm_pulse_transcript_dir() {
  printf '%s/%s\n' "${2%/}" "$(printf '%s' "$1" | tr '/.' '--')"
}

# fm_pulse_window <model> [tokens]: the assumed context window in tokens. 1M when the id
# names a 1M variant, names the opus or sonnet family (whose sessions run with a 1M window),
# or the last request already exceeded 200k (so it cannot be 200k); otherwise 200k, which
# covers haiku. An estimate, since the transcript does not record the window.
fm_pulse_window() {
  case "$1" in
    *"[1m]"* | *-1m | *-1m-* | *opus* | *sonnet*) printf '1000000\n'; return 0 ;;
  esac
  case "${2:-}" in '' | *[!0-9]*) ;; *) if [ "$2" -gt 200000 ]; then printf '1000000\n'; return 0; fi ;; esac
  printf '200000\n'
}

# fm_pulse_price <model>: "<input> <output> <cache_write> <cache_read>" in USD per million
# tokens. A small table keyed on the model family; unknown models price as sonnet.
# These are estimates, not billing data.
fm_pulse_price() {
  case "$1" in
    *fable* | *mythos*) printf '10 50 12.5 0.25\n' ;;
    *opus-5-5*) printf '4 20 5 0.2\n' ;;
    *opus*) printf '5 25 6.25 0.5\n' ;;
    *haiku-4*) printf '1 5 1.25 0.1\n' ;;
    *haiku*) printf '0.1 0.5 0.125 0.01\n' ;;
    *sonnet-4*) printf '3 15 3.75 0.3\n' ;;
    *) printf '2 10 2.5 0.2\n' ;;
  esac
}

# fm_pulse_percent <tokens> <window>: whole-number percent, capped at 100; empty when unknown.
fm_pulse_percent() {
  local tokens=$1 window=$2
  case "$tokens" in "" | *[!0-9]*) return 0 ;; esac
  case "$window" in "" | *[!0-9]*) return 0 ;; esac
  [ "$window" -gt 0 ] || return 0
  local pct=$((tokens * 100 / window))
  [ "$pct" -le 100 ] || pct=100
  printf '%s\n' "$pct"
}

# fm_pulse_usage_context: stdin = transcript JSONL (or its tail); stdout = one JSON object
# {tokens, model, title} from the LAST assistant usage row (context used = input + cache
# read + cache creation, the whole request) and the last ai-title row. A cut first line
# in a tail is skipped by fromjson's error handling. Synthetic and all-zero usage rows
# (interrupted turns) are not a context reading and are skipped. Prints {} when nothing parses.
fm_pulse_usage_context() {
  jq -R -c 'fromjson? // empty' 2>/dev/null | jq -s -c '
    ( [ .[] | select(.type == "assistant" and (.message.usage != null)
                     and (.message.model != "<synthetic>")
                     and (((.message.usage.input_tokens // 0)
                           + (.message.usage.cache_read_input_tokens // 0)
                           + (.message.usage.cache_creation_input_tokens // 0)) > 0)) ] | last ) as $a
    | ( [ .[] | select(.type == "ai-title") | .aiTitle ] | last ) as $t
    | {
        tokens: (if $a == null then null else
          (($a.message.usage.input_tokens // 0)
           + ($a.message.usage.cache_read_input_tokens // 0)
           + ($a.message.usage.cache_creation_input_tokens // 0)) end),
        model: ($a.message.model // null),
        effort: (if $a == null then null else ($a.effort // $a.perTurnEffort // null) end),
        title: $t
      }' 2>/dev/null
}

# fm_pulse_usage_cost <in> <out> <cache_write> <cache_read>: stdin = transcript JSONL;
# stdout = estimated USD with four decimals. Each assistant message id counts once (its
# last row wins, since streamed rows repeat the id); prices are per million tokens.
fm_pulse_usage_cost() {
  jq -R -c 'fromjson? // empty' 2>/dev/null | jq -s -r \
    --argjson pin "$1" --argjson pout "$2" --argjson pcw "$3" --argjson pcr "$4" '
    [ .[] | select(.type == "assistant" and (.message.usage != null)) ]
    | reduce .[] as $r ({}; .[($r.message.id // $r.uuid // "x")] = $r.message.usage)
    | [ .[] | ((.input_tokens // 0) * $pin
               + (.output_tokens // 0) * $pout
               + (.cache_creation_input_tokens // 0) * $pcw
               + (.cache_read_input_tokens // 0) * $pcr) ]
    | add // 0
    | . / 1000000
    | (. * 10000 | round) / 10000' 2>/dev/null
}

# fm_pulse_title <ai-title> <branch> <id>: the card title. The transcript's ai-title unless it
# is the generic "Firstmate operational ..." name every inbox-launched worker gets; then the
# branch with its `fm/` prefix and trailing `/<id>` removed (`fm/flapuz/MLP-1/x` -> `flapuz/MLP-1`).
fm_pulse_title() {
  local title=$1 branch=$2 id=$3
  case "$title" in "" | "Firstmate operational"*) title="" ;; esac
  if [ -z "$title" ]; then
    branch=${branch#fm/}
    branch=${branch%"/$id"}
    [ "$branch" != "$id" ] || branch=""
    title=$branch
  fi
  printf '%s\n' "$title"
}

# fm_pulse_newest_transcript <dir>: the most recently modified *.jsonl, or nothing.
fm_pulse_newest_transcript() {
  local f newest=""
  [ -d "$1" ] || return 0
  for f in "$1"/*.jsonl; do
    [ -f "$f" ] || continue
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest=$f; fi
  done
  [ -z "$newest" ] || printf '%s\n' "$newest"
}

# fm_pulse_stage <kind> <effective-state> <has-pr> <status-file> <started> <now>: where a worker is
# in its life, as `<label>US<step>US<total>` (US = unit separator). A ship runs start, build,
# validate, PR (4 steps); a scout runs start, investigate, report (3). Heuristic: a recorded PR
# means the PR step, a status log naming a pipeline or review means validate, a young quiet
# worker is starting, anything else is building. A `done` state means the last step.
fm_pulse_stage() {
  local kind=$1 eff=$2 haspr=$3 sfile=$4 started=$5 now=$6 log="" lines=0 age=0 us=$'\037'
  if [ -s "$sfile" ]; then
    log=$(tr 'A-Z' 'a-z' <"$sfile" 2>/dev/null)
    lines=$(wc -l <"$sfile" 2>/dev/null | tr -d ' ')
  fi
  [ -n "$started" ] && age=$((now - started))
  if [ "$kind" = scout ]; then
    if [ "$eff" = done ]; then printf '%s\n' "report ready${us}3${us}3"
    elif [ "$lines" -le 1 ] && [ "$age" -lt 300 ]; then printf '%s\n' "starting${us}1${us}3"
    else printf '%s\n' "investigating${us}2${us}3"; fi
    return 0
  fi
  if [ "$haspr" = 1 ]; then
    case "$log" in
      *"waiting on captain merge"* | *"awaiting"*merge*) printf '%s\n' "PR awaiting merge${us}4${us}4" ;;
      *) printf '%s\n' "PR open${us}4${us}4" ;;
    esac
  elif [ "$eff" = done ]; then
    printf '%s\n' "ready${us}4${us}4"
  else
    case "$log" in
      *no-mistakes* | *pipeline* | *review* | *validat* | *lint*) printf '%s\n' "validating${us}3${us}4" ;;
      *)
        if [ "$lines" -le 1 ] && [ "$age" -lt 300 ]; then printf '%s\n' "starting${us}1${us}4"
        else printf '%s\n' "building${us}2${us}4"; fi
        ;;
    esac
  fi
}

# fm_pulse_orca_names: a JSON object {worktree-path: Orca display name} from `orca worktree list`,
# so a card can carry the same name Orca shows for the task. `{}` when orca is absent or fails
# (FM_PULSE_NO_ORCA=1 skips the call); the card then falls back to the task id.
fm_pulse_orca_names() {
  if [ "${FM_PULSE_NO_ORCA:-}" = 1 ] || ! command -v orca >/dev/null 2>&1; then printf '{}'; return 0; fi
  orca worktree list --json 2>/dev/null \
    | jq -c '[ (.result.worktrees // [])[] | select((.path // "") != "" and (.displayName // "") != "") | { key: .path, value: .displayName } ] | from_entries' 2>/dev/null \
    || printf '{}'
}

# fm_pulse_queue <backlog.md>: the work that is not launched yet, as a JSON array of
# {id, title, repo, kind, since, held, blocked_by[]}, read from the `## Queued` section of the
# markdown backlog. `held` marks an item waiting on the captain. Empty array when the file is
# missing; a row that does not parse is skipped.
fm_pulse_queue() {
  [ -f "$1" ] || { printf '[]\n'; return 0; }
  awk '/^## /{ on = ($0 == "## Queued") } on && /^- \[ \] /' "$1" | jq -R -s -c '
    split("\n") | map(select(startswith("- [ ] ")))
    | map( ltrimstr("- [ ] ")
           | capture("^(?<id>[^ ]+) - (?<rest>.*)$")?
           | select(. != null)
           | .rest as $r
           | { id: .id,
               title: ($r | sub(" blocked-by:.*$"; "") | sub(" \\((repo: |kind: |since |hold:).*$"; "")),
               repo: (($r | capture("\\(repo: (?<v>[^)]*)\\)")? | .v) // null),
               kind: (($r | capture("\\(kind: (?<v>[^)]*)\\)")? | .v) // null),
               since: (($r | capture("\\(since (?<v>[0-9-]+)\\)")? | .v) // null),
               held: ($r | test("\\(hold:")),
               blocked_by: [ $r | scan("blocked-by: ([^ ]+)") | .[0] ] } )' 2>/dev/null || printf '[]\n'
}

# fm_pulse_graph <backlog.md>: every backlog item (In flight, Queued, Done) as a JSON array of
# {id, title, section, held, blocked_by[], soft_after[]}. `blocked_by` is the hard dependency
# tasks-axi records (`blocked-by: <id>`); `soft_after` comes from a `soft-after: <id>[, <id>]`
# line in the item's notes and means "related, but can run at the same time". Empty array when
# the file is missing.
fm_pulse_graph() {
  [ -f "$1" ] || { printf '[]\n'; return 0; }
  jq -R -s -c '
    split("\n") as $L
    | reduce $L[] as $line ({ sec: null, items: [], cur: null };
        if ($line | test("^## ")) then (.sec = ($line | ltrimstr("## ")) | .cur = null)
        elif ($line | test("^- \\[[ xX]\\] ")) then
          (($line | capture("^- \\[[ xX]\\] (?<id>[^ ]+) - (?<rest>.*)$")?) as $m
           | if $m == null then .cur = null else
               (.items += [ { id: $m.id, section: .sec,
                              held: ($m.rest | test("\\(hold:")),
                              blocked_by: [ $m.rest | scan("blocked-by: ([^ ]+)") | .[0] ],
                              soft_after: [],
                              title: ($m.rest | sub(" blocked-by:.*$"; "") | sub(" \\((repo: |kind: |since |hold:).*$"; "")) } ])
               | .cur = (.items | length - 1) end)
        elif (.cur != null and ($line | test("^\\s+")) and ($line | test("soft-after:"))) then
          (.items[.cur].soft_after += [ $line | sub("^.*soft-after:\\s*"; "") | split("[ ,]+"; null) | .[] | select(. != "") ])
        else . end)
    | .items | map(select(.section == "In flight" or .section == "Queued" or .section == "Done"))' "$1" 2>/dev/null || printf '[]\n'
}

# fm_pulse_worker <state-dir> <id> <projects-root> <now>: one worker as a JSON object.
fm_pulse_worker() {
  local state=$1 id=$2 projects=$3 now=$4
  local meta="$state/$id.meta"
  local kind harness model effort worktree branch
  kind=$(fm_pulse_meta_get "$meta" kind)
  harness=$(fm_pulse_meta_get "$meta" harness)
  model=$(fm_pulse_meta_get "$meta" model)
  effort=$(fm_pulse_meta_get "$meta" effort)
  worktree=$(fm_pulse_meta_get "$meta" worktree)
  branch=$(fm_pulse_meta_get "$meta" branch)
  local project
  project=$(fm_pulse_meta_get "$meta" project)
  project=${project%/}
  project=${project##*/}
  # spawn_gen is `s<epoch>.<pid>.<n>`: its epoch is when the worker was launched.
  local started
  started=$(fm_pulse_meta_get "$meta" spawn_gen | sed -n 's/^s\([0-9][0-9]*\)\..*/\1/p')

  local display=""
  [ -n "$worktree" ] && display=$(printf '%s' "${PULSE_ORCA_NAMES:-{\}}" | jq -r --arg p "$worktree" '.[$p] // empty' 2>/dev/null)
  local haspr=0
  [ -n "$(fm_pulse_meta_get "$meta" bb_pr)$(fm_pulse_meta_get "$meta" pr)" ] && haspr=1

  local busy=unknown busy_ts="" line
  if [ -f "$state/$id.busy-state" ]; then
    line=$(head -n 1 "$state/$id.busy-state" 2>/dev/null)
    IFS=$'\037' read -r busy busy_ts <<EOF
$(fm_pulse_parse_busy "$line")
EOF
  fi

  local word="" status_ts="" text=""
  if [ -s "$state/$id.status" ]; then
    line=$(tail -n 1 "$state/$id.status" 2>/dev/null)
    IFS=$'\037' read -r word status_ts text <<EOF
$(fm_pulse_parse_status "$line")
EOF
  fi

  local effective
  effective=$(fm_pulse_effective_state "$busy" "$busy_ts" "$word" "$status_ts")
  local last_event=${busy_ts:-0}
  if [ -n "$status_ts" ] && [ "$status_ts" -gt "$last_event" ]; then last_event=$status_ts; fi

  local stage_label stage_step stage_total
  IFS=$'\037' read -r stage_label stage_step stage_total <<EOF
$(fm_pulse_stage "$kind" "$effective" "$haspr" "$state/$id.status" "$started" "$now")
EOF

  local tokens="" tmodel="" teffort="" title="" window="" pct="" cost="" stats=null
  if [ "$harness" = claude ] && [ -n "$worktree" ]; then
    local dir transcript
    dir=$(fm_pulse_transcript_dir "$worktree" "$projects")
    transcript=$(fm_pulse_newest_transcript "$dir")
    if [ -n "$transcript" ]; then
      local ctx
      ctx=$(tail -c "$FM_PULSE_TAIL_BYTES" "$transcript" 2>/dev/null | fm_pulse_usage_context)
      tokens=$(printf '%s' "$ctx" | jq -r '.tokens // empty' 2>/dev/null)
      tmodel=$(printf '%s' "$ctx" | jq -r '.model // empty' 2>/dev/null)
      teffort=$(printf '%s' "$ctx" | jq -r '.effort // empty' 2>/dev/null)
      title=$(printf '%s' "$ctx" | jq -r '.title // empty' 2>/dev/null)
      stats=$(fm_pulse_dir_stats "$state" "$dir")
      [ -n "$stats" ] || stats=null
      cost=$(printf '%s' "$stats" | jq -r '.cost // empty' 2>/dev/null)
    fi
  fi
  window=$(fm_pulse_window "${tmodel:-$model}" "$tokens")
  [ -z "$tokens" ] || pct=$(fm_pulse_percent "$tokens" "$window")
  title=$(fm_pulse_title "$title" "$branch" "$id")

  local waiting=false
  case "$effective" in needs-decision | blocked | failed) waiting=true ;; esac

  jq -n -c \
    --arg id "$id" --arg kind "$kind" --arg harness "$harness" \
    --arg model "${tmodel:-$model}" --arg effort "${effort:-$teffort}" --arg title "$title" --arg state "$effective" \
    --arg busy "$busy" --argjson waiting "$waiting" --arg text "$text" \
    --arg status_at "$status_ts" --argjson last_event "$last_event" \
    --arg tokens "$tokens" --arg window "$window" --arg pct "$pct" --arg cost "$cost" \
    --arg started "$started" --argjson stats "$stats" --arg display "$display" --arg project "$project" --arg stage "$stage_label" --arg step "$stage_step" --arg total "$stage_total" '
    def num($s): if $s == "" then null else ($s | tonumber) end;
    {
      id: $id, kind: $kind, harness: $harness, model: $model, effort: (if $effort == "" then null else $effort end), title: $title,
      state: $state, busy: ($busy == "busy"), waiting_on_captain: $waiting,
      last_status: $text, last_status_at: num($status_at),
      last_event_at: (if $last_event == 0 then null else $last_event end),
      started_at: num($started),
      display: $display,
      project: $project,
      tokens_total: ($stats.tokens // null),
      by_model: ($stats.by_model // []),
      subagents: ($stats.subagents // []),
      stage: { label: $stage, step: num($step), total: num($total) },
      context: { tokens: num($tokens), window: num($window), pct: num($pct), estimate: true },
      tokens_breakdown: ($stats.breakdown // null),
      cost_usd: num($cost), cost_estimate: (($stats.exact // false) | not)
    }'
}

# fm_pulse_history <ledger> <spend> <now>: the history object on stdout. A task is finished
# when the ledger holds a task.merged, task.closed or task.cleaned_up record for it; its end
# is the newest of those, its start the oldest task.dispatched, and its outcome `merged` (via
# pr or local), `closed` (PR declined), else `cleaned_up`; `pr` is the newest PR link any
# record carried (null when none was ever recorded). Duplicate records collapse by task. Only tasks ended
# within the last 60 days are kept. Spend sums the spend ledger's records for the task,
# one per spawn_gen (a repeated record counts once). Missing or empty files give no rows.
fm_pulse_history() {
  local ledger=$1 spend=$2 now=$3 ltmp stmp
  ltmp=$(mktemp "${TMPDIR:-/tmp}/fm-pulse-ledger.XXXXXX") || return 1
  stmp=$(mktemp "${TMPDIR:-/tmp}/fm-pulse-spend.XXXXXX") || { rm -f "$ltmp"; return 1; }
  if [ -s "$ledger" ]; then jq -R -c 'fromjson? // empty' "$ledger" >"$ltmp" 2>/dev/null; fi
  if [ -s "$spend" ]; then jq -R -c 'fromjson? // empty' "$spend" >"$stmp" 2>/dev/null; fi
  jq -n -c --argjson now "$now" --slurpfile led "$ltmp" --slurpfile sp "$stmp" '
    ($led | map(select(type == "object" and (.ts | type) == "number" and (.task | type) == "string"))) as $L
    | ($sp | map(select(type == "object" and (.task | type) == "string"))) as $S
    | ($now - 60 * 86400) as $cut
    | ( reduce $S[] as $r ({}; .["\($r.task)|\($r.spawn_gen // "")"] = $r)
        | [ .[] ]
        | group_by(.task)
        | map({ key: .[0].task, value: {
            tokens: ([ .[] | ((.total.input_tokens.total // 0) + (.total.output_tokens.total // 0)) ] | add // 0),
            unknown: ([ .[] | ((.total.input_tokens.unknown // 0) + (.total.output_tokens.unknown // 0)) ] | add // 0)
          } })
        | from_entries ) as $spend
    | ( $L | group_by(.task) | map(
          . as $e
          | ([ $e[] | select(.event == "task.merged" or .event == "task.closed" or .event == "task.cleaned_up") | .ts ] | max) as $end
          | ([ $e[] | select(.event == "task.dispatched") | .ts ] | min) as $start
          | ([ $e[] | select(.event == "task.merged") ] | last) as $m
          | ([ $e[] | select(.event == "task.closed") ] | last) as $cl
          | select($end != null and $end >= $cut)
          | { task: $e[0].task,
              outcome: (if $m != null then "merged" elif $cl != null then "closed" else "cleaned_up" end),
              kind: ([ $e[] | select(.event == "task.dispatched") | .kind ] | map(select(. != null)) | last // null),
              pr: ([ $e[] | select(.event == "task.pr_ready" or .event == "task.merged" or .event == "task.closed" or .event == "task.cleaned_up") | .pr ] | map(select(. != null and . != "")) | last // null),
              via: ($m.via // null),
              project: ([ $e[] | select(.event == "task.dispatched") | .project ] | map(select(. != null)) | last // null),
              model: ([ $e[] | select(.event == "task.dispatched") | .model ] | map(select(. != null)) | last // null),
              dispatched_at: $start,
              ended_at: $end,
              duration_s: (if $start == null then null else ([$end - $start, 0] | max) end),
              spend_tokens: ($spend[$e[0].task].tokens // null),
              spend_unknown: ($spend[$e[0].task].unknown // 0) })
        | sort_by(-.ended_at) | .[0:200] ) as $rows
    | { ledger_since: ($L | map(.ts) | min), window_days: 60, rows: $rows }' 2>/dev/null
  local rc=$?
  rm -f "$ltmp" "$stmp"
  return "$rc"
}

# fm_pulse_build <state-dir> <projects-root> <now> [data-dir]: the whole pulse JSON on stdout.
fm_pulse_build() {
  local state=$1 projects=$2 now=$3 data=${4:-} meta id history
  [ -n "$data" ] || data=$(dirname "$state")/data
  history=$(fm_pulse_history "$state/fleet-ledger.jsonl" "$data/pipeline-spend.jsonl" "$now") || history=""
  [ -n "$history" ] || history='{"ledger_since":null,"window_days":60,"rows":[]}'
  history=$(fm_pulse_history_costs "$state" "$projects" "$history") || true
  PULSE_ORCA_NAMES=$(fm_pulse_orca_names)
  local queue
  queue=$(fm_pulse_queue "$data/backlog.md")
  [ -n "$queue" ] || queue='[]'
  local graph
  graph=$(fm_pulse_graph "$data/backlog.md")
  [ -n "$graph" ] || graph='[]'
  {
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] || continue
      id=${meta##*/}
      id=${id%.meta}
      fm_pulse_worker "$state" "$id" "$projects" "$now"
    done
  } | jq -s -c --argjson now "$now" --arg home "$state" --argjson history "$history" --argjson queue "$queue" --argjson graph "$graph" '
    . as $w
    | {
        version: 1, generated_at: $now, state_dir: $home, estimate: true, history: $history, queue: $queue, graph: $graph,
        workers: ($w | sort_by(.id)),
        counts: ($w | group_by(.state) | map({key: .[0].state, value: length}) | from_entries),
        total_cost_usd: (([ $w[] | .cost_usd // 0 ] | add // 0) * 10000 | round / 10000)
      }'
}

# fm_pulse_file_stats <file>: one transcript as a JSON array [{model, tokens, cost}], one entry per
# model that spoke in it. Each assistant message id counts once (its last row wins); `tokens` is
# input + output + cache write + cache read; `cost` is the estimated USD from the same price
# table as fm_pulse_price. Synthetic rows are ignored.
fm_pulse_file_stats() {
  jq -R -c 'fromjson? // empty' <"$1" 2>/dev/null | jq -s -c '
    def price(m): if (m | test("fable|mythos")) then [10, 50, 12.5, 0.25]
                  elif (m | test("opus-5-5")) then [4, 20, 5, 0.2]
                  elif (m | test("opus")) then [5, 25, 6.25, 0.5]
                  elif (m | test("haiku-4")) then [1, 5, 1.25, 0.1]
                  elif (m | test("haiku")) then [0.1, 0.5, 0.125, 0.01]
                  elif (m | test("sonnet-4")) then [3, 15, 3.75, 0.3]
                  else [2, 10, 2.5, 0.2] end;
    ([ .[] | select(.type == "cost-state" and (.modelUsage | type) == "object") ] | last) as $cs
    | ([ .[] | select(.type == "assistant" and (.message.model // "") != "" and (.effort // .perTurnEffort) != null) ]
       | group_by(.message.model) | map({ key: .[0].message.model, value: (last | (.effort // .perTurnEffort)) }) | from_entries) as $eff
    | if $cs != null then
        [ $cs.modelUsage | to_entries[] | .key as $m | .value as $u
          | { model: $m,
              input: ($u.inputTokens // 0), output: ($u.outputTokens // 0),
              cache_read: ($u.cacheReadInputTokens // 0), cache_write: ($u.cacheCreationInputTokens // 0),
              thinking: ($u.thinkingTokens // 0),
              tokens: (($u.inputTokens // 0) + ($u.outputTokens // 0) + ($u.cacheReadInputTokens // 0) + ($u.cacheCreationInputTokens // 0)),
              cost: ($u.costUSD // 0), exact: true } ]
      else
        [ .[] | select(.type == "assistant" and (.message.usage != null)) ]
        | reduce .[] as $r ({}; .[($r.message.id // $r.uuid // "x")] = { m: ($r.message.model // "unknown"), u: $r.message.usage })
        | [ .[] ] | group_by(.m)
        | map(. as $g | .[0].m as $m | price($m) as $p
            | ([ $g[] | (.u.input_tokens // 0) ] | add // 0) as $in
            | ([ $g[] | (.u.output_tokens // 0) ] | add // 0) as $out
            | ([ $g[] | (.u.cache_creation_input_tokens // 0) ] | add // 0) as $cw
            | ([ $g[] | (.u.cache_read_input_tokens // 0) ] | add // 0) as $cr
            | { model: $m, input: $in, output: $out, cache_read: $cr, cache_write: $cw, thinking: 0,
                tokens: ($in + $out + $cw + $cr),
                cost: (($in * $p[0] + $out * $p[1] + $cw * $p[2] + $cr * $p[3]) / 1000000), exact: false })
      end
    | map(select(.model != "<synthetic>") | . + { effort: ($eff[.model] // null) })' 2>/dev/null
}

# fm_pulse_file_stats_cached <state-dir> <file> [<agent-type>]: `{"type": ..., "stats": ...}` for
# one transcript, where stats is fm_pulse_file_stats, remembered in state/.fleet-stats-cache by
# file path, size and mtime so only a transcript that grew is read again. A file over
# FM_PULSE_STATS_MAX_BYTES (default 200 MB) counts as empty.
fm_pulse_file_stats_cached() {
  local state=$1 f=$2 type=${3:-} cache="$1/.fleet-stats-cache" st key hit size stats
  st=$(stat -f '%z:%m' "$f" 2>/dev/null || stat -c '%s:%Y' "$f" 2>/dev/null)
  key="$f|$st|v4"
  hit=$(grep -F -- "$key	" "$cache" 2>/dev/null | tail -n 1 | cut -f2-)
  if [ -n "$hit" ]; then printf '%s\n' "$hit"; return 0; fi
  size=${st%%:*}
  stats='[]'
  if [ -z "$size" ] || ! [ "$size" -gt "${FM_PULSE_STATS_MAX_BYTES:-209715200}" ] 2>/dev/null; then
    stats=$(fm_pulse_file_stats "$f")
    [ -n "$stats" ] || stats='[]'
  fi
  hit=$(jq -n -c --arg t "$type" --argjson s "$stats" '{ type: $t, stats: $s }')
  printf '%s\t%s\n' "$key" "$hit" >>"$cache" 2>/dev/null
  printf '%s\n' "$hit"
}

# fm_pulse_dir_stats <state-dir> <transcript-dir>: everything one worktree's Claude sessions
# spent, as one JSON object {tokens, cost, subagents: [{type, model, agents, tokens, cost}]}, or
# `null` when it has no transcript. Every top-level session transcript counts toward the
# totals, and every `<session>/subagents/agent-*.jsonl` counts both there and, grouped by its
# agent type (from the sibling `.meta.json`) and the model it mostly used, in `subagents`
# (costliest first).
fm_pulse_dir_stats() {
  local state=$1 dir=$2 f role type meta cache="$1/.fleet-stats-cache"
  [ -d "$dir" ] || { printf 'null\n'; return 0; }
  # the per-file cache only grows by files that grew; start over when it gets large
  if [ -f "$cache" ] && [ "$(wc -c <"$cache" | tr -d ' ')" -gt 8000000 ]; then : >"$cache"; fi
  {
    for f in "$dir"/*.jsonl; do [ -f "$f" ] && printf 'main\t%s\n' "$f"; done
    for f in "$dir"/*/subagents/agent-*.jsonl; do [ -f "$f" ] && printf 'sub\t%s\n' "$f"; done
  } | while IFS=$'\t' read -r role f; do
    type=""
    if [ "$role" = sub ]; then
      meta="${f%.jsonl}.meta.json"
      type=$(jq -r '.agentType // empty' "$meta" 2>/dev/null)
      [ -n "$type" ] || type=agent
    fi
    printf '{"role":"%s","c":%s}\n' "$role" "$(fm_pulse_file_stats_cached "$state" "$f" "$type")"
  done | jq -s -c '
    . as $a
    | if ($a | length) == 0 then null else
      ([ $a[] | select(.role == "main") | .c.stats[] ]) as $main
      | ($main | length > 0 and all(.exact == true)) as $exact
      | (if $exact then $main else [ $a[].c.stats[] ] end) as $count
      | { tokens: ([ $count[].tokens ] | add // 0),
          cost: ((([ $count[].cost ] | add // 0) * 10000 | round) / 10000),
          exact: $exact,
          breakdown: { input: ([ $count[].input // 0 ] | add // 0), output: ([ $count[].output // 0 ] | add // 0),
                       cache_read: ([ $count[].cache_read // 0 ] | add // 0), cache_write: ([ $count[].cache_write // 0 ] | add // 0) },
          by_model: ([ $count[] ] | group_by(.model) | map({ model: .[0].model, tokens: (map(.tokens) | add), cost: (((map(.cost) | add) * 10000 | round) / 10000) })),
          model: (($main | max_by(.tokens)) // null | if . == null then null else .model end),
          effort: (($main | max_by(.tokens)) // null | if . == null then null else .effort end),
          subagents: (
            [ $a[] | select(.role == "sub") | { type: .c.type, model: ((.c.stats | max_by(.tokens) // { model: "unknown" }) | .model),
                                                effort: ((.c.stats | max_by(.tokens) // {}) | .effort // null),
                                                tokens: ([ .c.stats[].tokens ] | add // 0), cost: ([ .c.stats[].cost ] | add // 0) } ]
            | group_by([.type, .model])
            | map({ type: .[0].type, model: .[0].model, effort: ([ .[].effort | select(. != null) ] | last), agents: length,
                    tokens: (map(.tokens) | add),
                    cost: (((map(.cost) | add) * 10000 | round) / 10000) })
            | sort_by(-.cost)) }
      end' 2>/dev/null
}

# fm_pulse_history_costs <state-dir> <projects-root> <history-json>: the history object with
# tokens, cost_usd and subagents added to every row from the task's transcripts (project
# directories ending `-fm-<task>`; the worktree is gone but its transcripts stay). A task
# with no transcript gets nulls and an empty subagent list.
fm_pulse_history_costs() {
  local state=$1 projects=$2 history=$3 task dir st proj obj="{}"
  for task in $(printf '%s' "$history" | jq -r '.rows[].task' 2>/dev/null); do
    for dir in "${projects%/}"/*-fm-"$task"; do
      [ -d "$dir" ] || continue
      st=$(fm_pulse_dir_stats "$state" "$dir")
      [ -n "$st" ] && [ "$st" != null ] || continue
      # the project is the folder between `workspaces-` and `-fm-<task>` in the transcript directory name
      proj=${dir##*/}
      proj=${proj##*-workspaces-}
      proj=${proj%"-fm-$task"}
      st=$(printf '%s' "$st" | jq -c --arg p "$proj" '. + { project: $p }')
      obj=$(printf '%s' "$obj" | jq -c --arg t "$task" --argjson s "$st" '
        .[$t] = (if .[$t] == null then $s else
          { project: .[$t].project, by_model: (.[$t].by_model + $s.by_model), model: (if .[$t].tokens >= $s.tokens then .[$t].model else $s.model end),
            effort: (if .[$t].tokens >= $s.tokens then .[$t].effort else $s.effort end), tokens: (.[$t].tokens + $s.tokens), cost: (.[$t].cost + $s.cost),
            exact: (.[$t].exact and $s.exact),
            breakdown: (.[$t].breakdown as $x | $s.breakdown as $y | if $x == null then $y elif $y == null then $x else
              { input: ($x.input + $y.input), output: ($x.output + $y.output), cache_read: ($x.cache_read + $y.cache_read), cache_write: ($x.cache_write + $y.cache_write) } end),
            subagents: (.[$t].subagents + $s.subagents) } end)')
    done
  done
  printf '%s' "$history" | jq -c --argjson d "$obj" '
    .rows |= map(. + { project: (.project // $d[.task].project // null), model: ($d[.task].model // .model // null), effort: ($d[.task].effort // null), by_model: ($d[.task].by_model // []), tokens: ($d[.task].tokens // null), cost_usd: ($d[.task].cost // null),
                       cost_exact: ($d[.task].exact // false), tokens_breakdown: ($d[.task].breakdown // null),
                       subagents: ($d[.task].subagents // []) })'
}

# fm_pulse_write <state-dir> <json>: atomic replace of state/.fleet-pulse.json.
fm_pulse_write() {
  local tmp
  tmp=$(mktemp "$1/.fleet-pulse.json.XXXXXX") || return 1
  if printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$1/.fleet-pulse.json"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

fm_pulse_main() {
  local mode=once interval=5 to_stdout=0 root home state data projects now json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '/^$/d'; return 0 ;;
      --once) mode=once ;;
      --loop)
        mode=loop
        case "${2:-}" in '' | -*) ;; *) interval=$2; shift ;; esac
        ;;
      --stdout) to_stdout=1 ;;
      *) echo "fm-fleet-pulse: unknown argument: $1" >&2; return 2 ;;
    esac
    shift
  done
  case "$interval" in '' | *[!0-9]* | 0) echo "fm-fleet-pulse: interval must be a positive integer" >&2; return 2 ;; esac
  command -v jq >/dev/null 2>&1 || { echo "fm-fleet-pulse: jq not found" >&2; return 1; }

  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  home=${FM_HOME:-$root}
  state=${FM_STATE_OVERRIDE:-$home/state}
  data=${FM_DATA_OVERRIDE:-$home/data}
  projects=${FM_PULSE_PROJECTS_DIR:-$HOME/.claude/projects}
  [ -d "$state" ] || { echo "fm-fleet-pulse: no state directory at $state" >&2; return 1; }

  while :; do
    now=${FM_PULSE_NOW:-$(date +%s)}
    json=$(fm_pulse_build "$state" "$projects" "$now" "$data") || { echo "fm-fleet-pulse: build failed" >&2; return 1; }
    if [ "$to_stdout" = 1 ]; then
      printf '%s\n' "$json"
    else
      fm_pulse_write "$state" "$json" || { echo "fm-fleet-pulse: cannot write pulse in $state" >&2; return 1; }
    fi
    [ "$mode" = loop ] || return 0
    # FM_PULSE_EXIT_WITH_LOCK=1 (set by fm-fleet-pulse-ensure.sh): stop when the session that
    # owns state/.lock has gone, so a background pulse never outlives firstmate.
    if [ "${FM_PULSE_EXIT_WITH_LOCK:-}" = 1 ]; then
      lockpid=$(head -n1 "$state/.lock" 2>/dev/null)
      case "$lockpid" in '' | *[!0-9]*) ;; *) kill -0 "$lockpid" 2>/dev/null || return 0 ;; esac
    fi
    sleep "$interval"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  fm_pulse_main "$@"
fi
