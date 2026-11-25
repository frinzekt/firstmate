#!/usr/bin/env bash
# bb-watch-poll.sh - one poll of a task's Bitbucket Cloud pull request, run by
# the state/<task-id>-bbwatch.check.sh wrapper bb-watch-install.sh writes.
# Notify-only: it never merges, approves, or tears anything down.
#
# Usage:
#   FM_HOME=<home> bb-watch-poll.sh <task-id> <pr-number> --workspace <slug>
#     --repo <slug> [--project <name>] [--ci-cmd <path>] [--ready-cmd <path>]
#     [--ignore-author <name>]... [--ignore-prefix <text>]...
#     [--park-days <n>] [--no-park] [--no-conflict-check]
#
# Prints at most one line, the watcher's wake reason, joining several events
# with " ; ", and nothing when nothing changed:
#   - new comments, one entry per comment with its author and link, skipping
#     deleted ones and any whose author display name is an --ignore-author or
#     whose text starts with an --ignore-prefix; the first poll records the
#     existing comments silently;
#   - a clean-to-conflict change against the destination (bb-conflict-check.sh);
#   - a park or resume of an idle worker (bb-park.sh);
#   - a change of PR state, CI verdict, or head: GREEN reports the PR ready for
#     review, FAILED is first sent to the worker through bin/fm-send.sh for one
#     fix attempt and is reported only when the worker cannot be reached, and a
#     DECLINED or SUPERSEDED PR is reported and recorded as a ledger closed
#     event. A MERGED PR is reported only when no firstmate merge poll is armed
#     for the task, because that poll already reports the merge.
# A RUNNING, NONE, or unreadable verdict on an open PR is transient and changes
# nothing. A failed read prints nothing, so a forge outage never alarms.
#
# The CI verdict defaults to the build statuses at the PR's full head (see
# bb_ci_verdict_from_json in bb-lib.sh). --ci-cmd replaces it: the command runs
# as `<path> <pr-number>` with FM_HOME exported and prints
# `<GREEN|FAILED|RUNNING|NONE> <head-sha>` on its first line; anything else
# reads as unknown.
#
# The watch retires itself through bin/fm-check-unregister.sh once the PR is
# closed or the task's metadata is gone. State, all under the home's state/:
# <id>.bbwatch.last (last state/verdict/head), <id>.bbwatch.comments (seen
# comment ids), plus the conflict and park records those scripts own.
set -u
BB_PROG=bb-watch-poll.sh
# shellcheck source=contrib/bitbucket/bb-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bb-lib.sh"

[ "$#" -ge 2 ] || bb_die 2 "usage: bb-watch-poll.sh <task-id> <pr-number> --workspace <slug> --repo <slug> [options]"
ID=$1 PR=$2
shift 2
WS='' REPO='' PROJECT='' CI_CMD='' READY_CMD='' PARK_DAYS=3 PARK=1 CONFLICT=1
IGNORE_AUTHORS='[]' IGNORE_PREFIXES='[]'
need() { [ "$#" -ge 2 ] || bb_die 2 "$1 needs a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace) need "$@"; WS=$2; shift ;;
    --repo) need "$@"; REPO=$2; shift ;;
    --project) need "$@"; PROJECT=$2; shift ;;
    --ci-cmd) need "$@"; CI_CMD=$2; shift ;;
    --ready-cmd) need "$@"; READY_CMD=$2; shift ;;
    --ignore-author) need "$@"; IGNORE_AUTHORS=$(jq -cn --argjson a "$IGNORE_AUTHORS" --arg v "$2" '$a + [$v]'); shift ;;
    --ignore-prefix) need "$@"; IGNORE_PREFIXES=$(jq -cn --argjson a "$IGNORE_PREFIXES" --arg v "$2" '$a + [$v]'); shift ;;
    --park-days) need "$@"; PARK_DAYS=$2; shift ;;
    --no-park) PARK=0 ;;
    --no-conflict-check) CONFLICT=0 ;;
    *) bb_die 2 "unknown option '$1'" ;;
  esac
  shift
done
bb_require_home
fm_pr_task_id_valid "$ID" || bb_die 2 "invalid task id '$ID'"
bb_require_number "the pull request number" "$PR"
bb_require_slugs "$WS" "$REPO"
[ -n "$PROJECT" ] || PROJECT=$REPO

STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
URL=https://bitbucket.org/$WS/$REPO/pull-requests/$PR
LAST=$STATE/$ID.bbwatch.last
SEEN=$STATE/$ID.bbwatch.comments
EVENTS=

event() { EVENTS="${EVENTS:+$EVENTS ; }$1"; }
finish() { [ -z "$EVENTS" ] || printf '%s\n' "$EVENTS"; exit 0; }
retire() {
  "$BB_FM_ROOT/bin/fm-check-unregister.sh" "$ID-bbwatch" >/dev/null 2>&1 || true
  rm -f -- "$LAST" "$SEEN" "$STATE/$ID.bbwatch.conflict"
}
ledger() {  # <event> <args>...
  [ -e "$CONFIG/fleet-ledger" ] || return 0
  FM_HOME=$FM_HOME "$BB_FM_ROOT/bin/fm-fleet-ledger.sh" "$@" >/dev/null 2>&1 || true
}

# A cleaned-up task leaves no metadata; its watch has nothing left to report.
if [ ! -f "$STATE/$ID.meta" ]; then
  retire
  exit 0
fi

pr_json=$(fm_pr_bitbucket_read_json "$WS/$REPO" "$PR") || exit 0
state=$(printf '%s' "$pr_json" | jq -r '.state') || exit 0
src=$(printf '%s' "$pr_json" | jq -r '.source.branch.name // ""')
dest=$(printf '%s' "$pr_json" | jq -r '.destination.branch.name // ""')

if [ -n "$CI_CMD" ]; then
  verdict=$(FM_HOME=$FM_HOME "$CI_CMD" "$PR" 2>/dev/null | head -1) || verdict=
else
  verdict=$(bb_ci_verdict_from_json "$pr_json") || verdict=
fi
pipe=${verdict%% *}
head=${verdict#* }
[ "$head" != "$verdict" ] || head=
case "$pipe" in
  GREEN|FAILED|RUNNING|NONE) ;;
  *) pipe=UNKNOWN ;;
esac

if [ "$state" = OPEN ]; then
  if [ "$CONFLICT" = 1 ]; then
    line=$("$BB_CONTRIB_DIR/bb-conflict-check.sh" "$ID" "$PROJECT" "$src" "$dest" "$PR" 2>/dev/null) || line=
    [ -z "$line" ] || event "$line"
  fi
  comments=$(fm_pr_bitbucket_twg pull-requests comment query "$PR" \
    --workspace "$WS" --repo "$REPO" -n 100) || comments=
  if [ -n "$comments" ] && printf '%s' "$comments" | jq -e 'type == "array"' >/dev/null 2>&1; then
    fresh=$(printf '%s' "$comments" | jq -c --argjson authors "$IGNORE_AUTHORS" \
      --argjson prefixes "$IGNORE_PREFIXES" '
      [ .[] | select(type == "object" and (.deleted | not))
        | select(((.user.display_name // "") as $n | $authors | index($n)) | not)
        | select((.content.raw // "") as $t | [$prefixes[] | select(. as $p | $p != "" and ($t | startswith($p)))] | length == 0)
        | {id: (.id | tostring), who: (.user.display_name // "someone"), link: (.links.html.href // "")} ]')
    if [ ! -f "$SEEN" ]; then
      printf '%s' "$fresh" | jq -r '.[].id' > "$SEEN"
    else
      n=0 list=
      while IFS=$'\037' read -r cid who link; do
        [ -n "$cid" ] || continue
        grep -qx -- "$cid" "$SEEN" && continue
        printf '%s\n' "$cid" >> "$SEEN"
        n=$((n + 1))
        list="${list:+$list, }$who $link"
      done <<COMMENTS
$(printf '%s' "$fresh" | jq -r '.[] | [.id, .who, .link] | map(gsub("[\u001f\n]"; " ")) | join("\u001f")')
COMMENTS
      [ "$n" -eq 0 ] || event "bitbucket PR $PR $n new comment(s): $list"
    fi
  fi
  if [ "$PARK" = 1 ] && [ "$PARK_DAYS" -gt 0 ] && [ -n "$comments" ]; then
    tmp_dir=$(mktemp -d "$STATE/.bb-watch.XXXXXX") || finish
    printf '%s' "$pr_json" > "$tmp_dir/pr.json"
    printf '%s' "$comments" > "$tmp_dir/comments.json"
    park_args=(--park-days "$PARK_DAYS")
    [ -z "$READY_CMD" ] || park_args+=(--ready-cmd "$READY_CMD")
    line=$("$BB_CONTRIB_DIR/bb-park.sh" "$ID" "$PR" "$URL" "$tmp_dir/pr.json" \
      "$tmp_dir/comments.json" "$pipe" "${park_args[@]}" 2>/dev/null) || line=
    rm -rf -- "$tmp_dir"
    [ -z "$line" ] || event "$line"
  fi
  case "$pipe" in
    UNKNOWN|RUNNING|NONE) finish ;;
  esac
fi

cur="$state/$pipe/$head"
[ "$(cat "$LAST" 2>/dev/null)" != "$cur" ] || finish
printf '%s\n' "$cur" > "$LAST"
case "$state" in
  MERGED)
    [ -f "$STATE/$ID.check.sh" ] || event "bitbucket PR $PR MERGED: $URL"
    retire
    ;;
  DECLINED|SUPERSEDED)
    ledger closed "$ID" pr "$URL"
    event "bitbucket PR $PR $state: $URL"
    retire
    ;;
  OPEN)
    case "$pipe" in
      FAILED)
        if ! FM_HOME=$FM_HOME "$BB_FM_ROOT/bin/fm-send.sh" "$ID" "[auto] PR $PR has a failed build on head $head ($URL). Investigate the failing pipeline and its logs, make ONE fix attempt, push, and watch the build again. Append a blocked status only if that fix does not resolve it." >/dev/null 2>&1; then
          event "bitbucket PR $PR build FAILED and worker $ID could not be reached: $URL"
        fi
        ;;
      GREEN) event "bitbucket PR $PR checks passed on $head (ready for review): $URL" ;;
    esac
    ;;
esac
finish
