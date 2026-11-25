#!/usr/bin/env bash
# bb-conflict-check.sh - report when a pull request's source branch newly
# conflicts with its destination. Notify-only: it never touches the project
# clone's work tree or any branch.
#
# Usage:
#   FM_HOME=<home> bb-conflict-check.sh <task-id> <project> <source-branch> <dest-branch> <pr-number>
#
# <project> names the clone at $FM_HOME/projects/<project>. A per-task scratch
# clone under state/.cc/<task-id> shares that clone's objects and its origin
# URL; each run fetches the two branches into it and runs
# `git merge-tree --write-tree`. It prints one line only on the change from
# clean (or first sight) to conflicted, naming up to five conflicting files,
# and nothing otherwise. state/<task-id>.bbwatch.conflict holds the last
# result, "clean" or "conflict", which bb-park.sh also reads. Any error exits
# 0 silently, so a fetch failure never raises a false alarm.
set -u
BB_PROG=bb-conflict-check.sh
# shellcheck source=contrib/bitbucket/bb-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bb-lib.sh"

[ "$#" -eq 5 ] || bb_die 2 "usage: bb-conflict-check.sh <task-id> <project> <source-branch> <dest-branch> <pr-number>"
ID=$1 PROJECT=$2 BR=$3 DEST=$4 PR=$5
bb_require_home
fm_pr_task_id_valid "$ID" || bb_die 2 "invalid task id '$ID'"
fm_task_id_path_safe "$PROJECT" || bb_die 2 "invalid project name '$PROJECT'"
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
P=$FM_HOME/projects/$PROJECT
[ -e "$P/.git" ] || exit 0
for b in "$BR" "$DEST"; do
  [ -n "$b" ] && [ "$b" != null ] || exit 0
  git check-ref-format --branch "$b" >/dev/null 2>&1 || exit 0
done
CC=$STATE/.cc/$ID
if [ ! -d "$CC/.git" ]; then
  mkdir -p "$STATE/.cc" || exit 0
  git clone -q --shared --no-checkout "$P" "$CC" 2>/dev/null || exit 0
  origin=$(git -C "$P" remote get-url origin 2>/dev/null) || exit 0
  git -C "$CC" remote set-url origin "$origin" || exit 0
fi
git -C "$CC" fetch -q origin "+refs/heads/$DEST:refs/remotes/origin/$DEST" \
  "+refs/heads/$BR:refs/remotes/origin/$BR" 2>/dev/null || exit 0
rc=0
out=$(git -C "$CC" merge-tree --write-tree --name-only "origin/$DEST" "origin/$BR" 2>/dev/null) || rc=$?
case $rc in
  0) now=clean ;;
  1) now=conflict ;;
  *) exit 0 ;;
esac
LAST=$STATE/$ID.bbwatch.conflict
prev=$(cat "$LAST" 2>/dev/null || echo seed)
printf '%s\n' "$now" > "$LAST"
if [ "$now" = conflict ] && [ "$prev" != conflict ]; then
  files=$(printf '%s\n' "$out" | sed -n '2,/^$/p' | sed '/^$/d' | head -5 | paste -sd, -)
  echo "bitbucket PR $PR CONFLICTS with $DEST; bring the branch up to date with $DEST: $files"
fi
exit 0
