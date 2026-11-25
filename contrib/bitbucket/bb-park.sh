#!/usr/bin/env bash
# bb-park.sh - park the worker of an open Bitbucket Cloud pull request that has
# had no activity for a number of weekdays, and resume it on new activity.
# Called by bb-watch-poll.sh for open pull requests only. It never merges and
# never tears down: parking stops only the agent, keeping its branch, local
# copy, and pull request.
#
# Usage:
#   FM_HOME=<home> bb-park.sh <task-id> <pr-number> <pr-url> <pr.json>
#     <comments.json> <ci-verdict> [--park-days <n>] [--ready-cmd <path>]
#
# <pr.json> is one `twg bitbucket pull-requests get --statuses` record and
# <comments.json> its `pull-requests comment query` list. Activity is the
# newest of the pull request's updated_on and every comment's created_on and
# updated_on, so any comment resets the clock.
#
# Park when every condition holds: the task is not already parked, the verdict
# is GREEN, the last conflict check (state/<id>.bbwatch.conflict) is not
# "conflict", the optional --ready-cmd (BB_READY_CMD), run as `<path>
# <pr-number>` with FM_HOME exported, exits 0, bin/fm-crew-state.sh reports the
# worker done or paused, and activity is at least --park-days (BB_PARK_DAYS,
# default 3) weekdays old, counted in local time. Parking writes resume notes
# to data/<id>/parked.md, stops the agent with `bin/fm-control.sh <id> exit`,
# records state/<id>.bbpark (parked_at=<epoch>, head=<sha>), appends a paused
# status line, and prints one line.
# Resume a parked task on activity newer than the park time, or on a FAILED
# verdict, with `bin/fm-control.sh <id> relaunch --note-file data/<id>/parked.md`,
# then print one line; a failed relaunch prints the command to run by hand.
set -u
BB_PROG=bb-park.sh
# shellcheck source=contrib/bitbucket/bb-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bb-lib.sh"

[ "$#" -ge 6 ] || bb_die 2 "usage: bb-park.sh <task-id> <pr-number> <pr-url> <pr.json> <comments.json> <ci-verdict> [--park-days <n>] [--ready-cmd <path>]"
ID=$1 PR=$2 URL=$3 F=$4 CF=$5 CI=$6
shift 6
PARK_DAYS=${BB_PARK_DAYS:-3} READY_CMD=${BB_READY_CMD:-}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --park-days) [ "$#" -ge 2 ] || bb_die 2 "--park-days needs a value"; PARK_DAYS=$2; shift ;;
    --ready-cmd) [ "$#" -ge 2 ] || bb_die 2 "--ready-cmd needs a value"; READY_CMD=$2; shift ;;
    *) bb_die 2 "unknown option '$1'" ;;
  esac
  shift
done
bb_require_home
fm_pr_task_id_valid "$ID" || bb_die 2 "invalid task id '$ID'"
bb_require_number "the pull request number" "$PR"
case "$PARK_DAYS" in ''|*[!0-9]*) bb_die 2 "--park-days must be a whole number of weekdays" ;; esac
bb_require_tools jq
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
REC=$STATE/$ID.bbpark
DOC=$FM_HOME/data/$ID/parked.md
STATUS=$STATE/$ID.status
[ -f "$F" ] || exit 0

iso() { date -u -r "$1" +%FT%TZ 2>/dev/null || date -u -d "@$1" +%FT%TZ; }

# Newest activity, as epoch seconds; fractional seconds and offsets are
# normalized for jq's fromdateiso8601.
# shellcheck disable=SC2016 # jq program text, not shell expansions.
act=$(jq -rn --slurpfile pr "$F" --slurpfile cs "$CF" '
  def ts: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
  [ ($pr[0] | if type == "array" then .[0] else . end | .updated_on // empty),
    ($cs[0] | if type == "array" then .[] else empty end | (.created_on, .updated_on) | select(. != null)) ]
  | map(select(type == "string") | ts) | max // empty | floor' 2>/dev/null) || exit 0
case "$act" in ''|*[!0-9]*) exit 0 ;; esac
now=$(date +%s)

if [ -f "$REC" ]; then
  parked_at=$(sed -n 's/^parked_at=//p' "$REC")
  case "$parked_at" in ''|*[!0-9]*) exit 0 ;; esac
  trig=
  [ "$act" -le $((parked_at + 60)) ] || trig="new PR activity at $(iso "$act")"
  [ "$CI" != FAILED ] || trig="${trig:+$trig; }a build FAILED"
  [ -n "$trig" ] || exit 0
  mkdir -p "$FM_HOME/data/$ID"
  printf '\nResumed %s. Trigger: %s.\n' "$(iso "$now")" "$trig" >> "$DOC"
  printf 'working [at=%s]: resuming parked PR %s (%s); read %s first\n' "$now" "$PR" "$trig" "$DOC" >> "$STATUS"
  if FM_HOME=$FM_HOME "$BB_FM_ROOT/bin/fm-control.sh" "$ID" relaunch --note-file "$DOC" >/dev/null 2>&1; then
    rm -f -- "$REC"
    echo "bitbucket PR $PR worker $ID resumed from parked ($trig): $URL"
  else
    echo "bitbucket PR $PR worker $ID could not be resumed after parking ($trig): $URL - relaunch by hand with bin/fm-control.sh $ID relaunch --note-file $DOC"
  fi
  exit 0
fi

[ "$PARK_DAYS" -gt 0 ] || exit 0
[ "$CI" = GREEN ] || exit 0
[ "$(cat "$STATE/$ID.bbwatch.conflict" 2>/dev/null)" != conflict ] || exit 0

# Weekday time elapsed since the last activity, in local time.
idle_ok=$(python3 - "$act" "$now" "$PARK_DAYS" <<'PY'
import sys, datetime as d
a, n, days = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
t = a
tot = 0.0
while t < n:
    midnight = d.datetime.fromtimestamp(t).replace(hour=0, minute=0, second=0, microsecond=0)
    nxt = min(n, (midnight + d.timedelta(days=1)).timestamp())
    if d.datetime.fromtimestamp(t).weekday() < 5:
        tot += nxt - t
    t = nxt
print("1" if tot / 86400 >= days else "0")
PY
) || exit 0
[ "$idle_ok" = 1 ] || exit 0
if [ -n "$READY_CMD" ]; then
  FM_HOME=$FM_HOME "$READY_CMD" "$PR" >/dev/null 2>&1 || exit 0
fi
st=$(FM_HOME=$FM_HOME "$BB_FM_ROOT/bin/fm-crew-state.sh" "$ID" 2>/dev/null | head -1)
case "$st" in
  "state: done"*|"state: paused"*) ;;
  *) exit 0 ;;
esac
pr_json=$(jq -c 'if type == "array" then .[0] else . end' "$F") || exit 0
head=$(printf '%s' "$pr_json" | jq -r "$FM_PR_BITBUCKET_JQ_DEFS"' bb_head' 2>/dev/null) || head=
title=$(printf '%s' "$pr_json" | jq -r '.title // ""')
branch=$(printf '%s' "$pr_json" | jq -r '.source.branch.name // ""')
revs=$(printf '%s' "$pr_json" | jq -r '[.participants[]? | select(.role == "REVIEWER") | (.user.display_name + (if .approved then " (approved)" else "" end))] | join(", ")')
mkdir -p "$FM_HOME/data/$ID"
cat > "$DOC" <<DOCEOF
# Parked: $ID - PR $PR

- PR: $URL
- Title: $title
- Branch: $branch (head ${head:-unresolved})
- Parked: $(iso "$now") after $PARK_DAYS or more weekdays with no PR activity (last activity $(iso "$act"))
- State when parked: PR open, every build green at the head, no conflict with the destination
- Reviewers: $revs
- Worker last status: $(tail -1 "$STATUS" 2>/dev/null | cut -c1-300)
- The local copy and branch are preserved; only the agent was stopped.

## To continue
This resumes automatically on new PR activity or a failed build. By hand:
  bin/fm-control.sh $ID relaunch --note-file $DOC
On resume: re-read the PR comments since the park time and address them, bring the branch up to date with its destination if it is behind, push, and watch the build.
DOCEOF
if FM_HOME=$FM_HOME "$BB_FM_ROOT/bin/fm-control.sh" "$ID" exit >/dev/null 2>&1; then
  printf 'parked=1\nparked_at=%s\nhead=%s\n' "$now" "$head" > "$REC"
  printf 'paused [at=%s]: parked after %s weekdays idle on PR %s; notes %s; resumes on PR activity or a failed build\n' "$now" "$PARK_DAYS" "$PR" "$DOC" >> "$STATUS"
  echo "bitbucket PR $PR worker $ID parked (idle $PARK_DAYS or more weekdays; notes $DOC): $URL"
else
  rm -f -- "$DOC"
fi
