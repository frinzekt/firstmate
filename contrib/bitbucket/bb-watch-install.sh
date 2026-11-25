#!/usr/bin/env bash
# bb-watch-install.sh - arm a notify-only review watch on a task's Bitbucket
# Cloud pull request. It never merges, approves, or tears anything down.
#
# Usage:
#   FM_HOME=<home> bb-watch-install.sh <task-id> <pr-number> [options]
#
# Options (each also read from the named environment variable):
#   --workspace <slug>      BB_WORKSPACE   Bitbucket workspace (required)
#   --repo <slug>           BB_REPO        repository slug (required)
#   --project <name>        BB_PROJECT     clone under $FM_HOME/projects used for
#                                          the conflict check (default: the repo slug)
#   --ci-cmd <path>         BB_CI_CMD      CI verdict command (see bb-watch-poll.sh)
#   --ready-cmd <path>      BB_READY_CMD   extra parking gate (see bb-park.sh)
#   --ignore-author <name>  BB_IGNORE_AUTHORS   comment author display name to
#                                          ignore; repeatable, env is newline-separated
#   --ignore-prefix <text>  BB_IGNORE_PREFIXES  comment text prefix to ignore;
#                                          repeatable, env is newline-separated
#   --park-days <n>         BB_PARK_DAYS   idle weekdays before parking (default 3)
#   --no-park                              never park the worker
#   --no-conflict-check                    skip the destination conflict check
#   --no-pr-check                          do not register the pull request
#                                          through bin/fm-pr-check.sh
#
# What it does:
#   1. Unless --no-pr-check, runs bin/fm-pr-check.sh <task-id> <pr-url>, which
#      records pr= in the task metadata, arms firstmate's own merge poll, and
#      writes the ledger's pr_ready record; bin/fm-pr-merge.sh then owns any
#      merge.
#   2. Writes state/<task-id>-bbwatch.check.sh (mode 0700), a thin wrapper that
#      runs this directory's bb-watch-poll.sh with the options above baked in,
#      and binds it with bin/fm-check-register.sh. The watcher then runs it on
#      every check sweep; bb-watch-poll.sh's header owns what it reports.
# The wrapper calls bb-watch-poll.sh in place, so moving this checkout breaks
# the watch until it is installed again.
set -eu
BB_PROG=bb-watch-install.sh
# shellcheck source=contrib/bitbucket/bb-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bb-lib.sh"

usage() { sed -n '2,/^set -eu$/{/^set -eu$/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -ge 2 ] || { usage >&2; exit 2; }

ID=$1 PR=$2
shift 2
WS=${BB_WORKSPACE:-} REPO=${BB_REPO:-} PROJECT=${BB_PROJECT:-}
CI_CMD=${BB_CI_CMD:-} READY_CMD=${BB_READY_CMD:-} PARK_DAYS=${BB_PARK_DAYS:-3}
PARK=1 CONFLICT=1 PR_CHECK=1
IGNORE_AUTHORS=() IGNORE_PREFIXES=()
while IFS= read -r line; do [ -z "$line" ] || IGNORE_AUTHORS+=("$line"); done <<EOF
${BB_IGNORE_AUTHORS:-}
EOF
while IFS= read -r line; do [ -z "$line" ] || IGNORE_PREFIXES+=("$line"); done <<EOF
${BB_IGNORE_PREFIXES:-}
EOF
need() { [ "$#" -ge 2 ] || bb_die 2 "$1 needs a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace) need "$@"; WS=$2; shift ;;
    --repo) need "$@"; REPO=$2; shift ;;
    --project) need "$@"; PROJECT=$2; shift ;;
    --ci-cmd) need "$@"; CI_CMD=$2; shift ;;
    --ready-cmd) need "$@"; READY_CMD=$2; shift ;;
    --ignore-author) need "$@"; IGNORE_AUTHORS+=("$2"); shift ;;
    --ignore-prefix) need "$@"; IGNORE_PREFIXES+=("$2"); shift ;;
    --park-days) need "$@"; PARK_DAYS=$2; shift ;;
    --no-park) PARK=0 ;;
    --no-conflict-check) CONFLICT=0 ;;
    --no-pr-check) PR_CHECK=0 ;;
    *) bb_die 2 "unknown option '$1'" ;;
  esac
  shift
done

bb_require_home
fm_pr_task_id_valid "$ID" || bb_die 2 "invalid task id '$ID'"
bb_require_number "the pull request number" "$PR"
bb_require_slugs "$WS" "$REPO"
[ -n "$PROJECT" ] || PROJECT=$REPO
fm_task_id_path_safe "$PROJECT" || bb_die 2 "invalid project name '$PROJECT'"
case "$PARK_DAYS" in ''|*[!0-9]*) bb_die 2 "--park-days must be a whole number of weekdays" ;; esac
for cmd in "$CI_CMD" "$READY_CMD"; do
  [ -z "$cmd" ] || [ -x "$cmd" ] || bb_die 2 "'$cmd' is not an executable file"
done
bb_require_tools twg jq git

STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
[ -f "$STATE/$ID.meta" ] || bb_die 1 "task $ID has no metadata in $STATE"
URL=https://bitbucket.org/$WS/$REPO/pull-requests/$PR

if [ "$PR_CHECK" = 1 ]; then
  "$BB_FM_ROOT/bin/fm-pr-check.sh" "$ID" "$URL"
fi

args=(--workspace "$WS" --repo "$REPO" --project "$PROJECT" --park-days "$PARK_DAYS")
[ -z "$CI_CMD" ] || args+=(--ci-cmd "$CI_CMD")
[ -z "$READY_CMD" ] || args+=(--ready-cmd "$READY_CMD")
[ "$PARK" = 1 ] || args+=(--no-park)
[ "$CONFLICT" = 1 ] || args+=(--no-conflict-check)
for a in "${IGNORE_AUTHORS[@]+"${IGNORE_AUTHORS[@]}"}"; do args+=(--ignore-author "$a"); done
for p in "${IGNORE_PREFIXES[@]+"${IGNORE_PREFIXES[@]}"}"; do args+=(--ignore-prefix "$p"); done

CHECK_ID=$ID-bbwatch
CHECK=$STATE/$CHECK_ID.check.sh
umask 077
TMP=$(mktemp "$STATE/.bb-watch-install.XXXXXX")
trap '[ -z "${TMP:-}" ] || rm -f -- "$TMP"' EXIT
{
  printf '#!/usr/bin/env bash\n'
  printf '# Generated by contrib/bitbucket/bb-watch-install.sh; re-run it to change.\n'
  printf 'FM_HOME=%q exec %q %q %q' "$FM_HOME" "$BB_CONTRIB_DIR/bb-watch-poll.sh" "$ID" "$PR"
  printf ' %q' "${args[@]}"
  printf '\n'
} > "$TMP"
chmod 0700 "$TMP"
mv -f -- "$TMP" "$CHECK"
TMP=
FM_HOME=$FM_HOME "$BB_FM_ROOT/bin/fm-check-register.sh" "$CHECK_ID"
