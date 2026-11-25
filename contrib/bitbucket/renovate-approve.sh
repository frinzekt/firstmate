#!/usr/bin/env bash
# renovate-approve.sh - approve a dependency bot's open, green Bitbucket Cloud
# pull requests in one repository. Dry run by default: it lists each decision
# and approves nothing unless --apply is passed. It never merges.
#
# Usage:
#   renovate-approve.sh --workspace <slug> --repo <slug> --bot-account-id <id>
#     --my-account-id <id> [--bot-nickname <name>] [--days <n>]
#     [--skip-word <word>]... [--status-key-prefix <prefix>] [--apply]
#
# Options (each also read from the named environment variable):
#   --workspace <slug>          BB_WORKSPACE          Bitbucket workspace (required)
#   --repo <slug>               BB_REPO               repository slug (required)
#   --bot-account-id <id>       BB_BOT_ACCOUNT_ID     the bot's Atlassian account ID (required)
#   --my-account-id <id>        BB_MY_ACCOUNT_ID      your own account ID, to skip what you
#                                                     already approved (required)
#   --bot-nickname <name>       BB_BOT_NICKNAME       when set, the author nickname must match too
#   --days <n>                  BB_DAYS               only PRs created in the last n days (default 14)
#   --skip-word <word>          BB_SKIP_WORDS         never approve a PR whose title or source
#                                                     branch contains the word, case-insensitive;
#                                                     repeatable, env is space-separated
#   --status-key-prefix <p>     BB_STATUS_KEY_PREFIX  require a SUCCESSFUL status whose key starts
#                                                     with p (default: any status)
#   --apply                                           approve instead of listing
#
# A PR is approved only when the bot authored it, it is within --days, no skip
# word matches, at least one build status reported at its full head (matching
# --status-key-prefix when set), every status at the head is SUCCESSFUL, and
# you have not approved it already.
set -u
BB_PROG=renovate-approve.sh
# shellcheck source=contrib/bitbucket/bb-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bb-lib.sh"

usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; }
WS=${BB_WORKSPACE:-} REPO=${BB_REPO:-} BOTID=${BB_BOT_ACCOUNT_ID:-} ME=${BB_MY_ACCOUNT_ID:-}
BOT=${BB_BOT_NICKNAME:-} DAYS=${BB_DAYS:-14} KEY_PREFIX=${BB_STATUS_KEY_PREFIX:-} APPLY=0
read -r -a SKIP_WORDS <<<"${BB_SKIP_WORDS:-}"
need() { [ "$#" -ge 2 ] || bb_die 2 "$1 needs a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --workspace) need "$@"; WS=$2; shift ;;
    --repo) need "$@"; REPO=$2; shift ;;
    --bot-account-id) need "$@"; BOTID=$2; shift ;;
    --my-account-id) need "$@"; ME=$2; shift ;;
    --bot-nickname) need "$@"; BOT=$2; shift ;;
    --days) need "$@"; DAYS=$2; shift ;;
    --skip-word) need "$@"; SKIP_WORDS+=("$2"); shift ;;
    --status-key-prefix) need "$@"; KEY_PREFIX=$2; shift ;;
    --apply) APPLY=1 ;;
    *) bb_die 2 "unknown option '$1'" ;;
  esac
  shift
done
bb_require_slugs "$WS" "$REPO"
[ -n "$BOTID" ] || bb_die 2 "the bot's account ID is required (--bot-account-id or BB_BOT_ACCOUNT_ID)"
[ -n "$ME" ] || bb_die 2 "your account ID is required (--my-account-id or BB_MY_ACCOUNT_ID)"
bb_require_number "--days" "$DAYS"
bb_require_tools twg jq

ids=
page=1
while [ "$page" -le 20 ]; do
  js=$(fm_pr_bitbucket_twg pull-requests query --workspace "$WS" --repo "$REPO" --author "$BOTID" \
    --state OPEN --created-since "${DAYS}d" -n 100 --page "$page") \
    || bb_die 1 "the pull request query failed (page $page)"
  pg=$(printf '%s' "$js" | jq -r '(if type == "object" then (.values // []) else . end) | .[].id' 2>/dev/null) \
    || bb_die 1 "the pull request query returned unreadable JSON (page $page)"
  [ -n "$pg" ] || break
  ids="$ids $pg"
  [ "$(printf '%s' "$js" | jq -r 'if type == "object" then (.hasNextPage // false) else false end')" = true ] || break
  page=$((page + 1))
done
# shellcheck disable=SC2086 # Word-splitting the id list is intended.
ids=$(printf '%s\n' $ids | sort -un)
[ -n "$ids" ] || { echo "no open bot PRs created in the last $DAYS days"; exit 0; }
echo "candidates: $(printf '%s\n' "$ids" | wc -l | tr -d ' ')"

cutoff=$(( $(date +%s) - DAYS * 86400 ))
ok=0 skip=0
for id in $ids; do
  if ! g=$(fm_pr_bitbucket_read_json "$WS/$REPO" "$id"); then
    echo "#$id skip: lookup failed"; skip=$((skip + 1)); continue
  fi
  # shellcheck disable=SC2016 # jq program text, not shell expansions.
  facts=$(printf '%s' "$g" | jq -r --arg me "$ME" --arg kp "$KEY_PREFIX" "$FM_PR_BITBUCKET_JQ_DEFS"'
    bb_head as $h
    | [bb_statuses[] | select($h != "" and (.commit.hash // "") == $h)] as $s
    | [ ((.created_on // "") | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | (try fromdateiso8601 catch 0) | floor | tostring),
        (.author.account_id // ""),
        (.author.nickname // ""),
        (if $h == "" then "unresolved"
         elif ($s | length) == 0 then "none"
         elif ($kp != "" and ([$s[] | select((.key // "") | startswith($kp)) | select(.state == "SUCCESSFUL")] | length) == 0) then "no-" + $kp
         elif any($s[]; .state != "SUCCESSFUL") then ([$s[] | select(.state != "SUCCESSFUL") | .state] | unique | join("+"))
         else "green" end),
        ([.participants[]? | select(.approved == true and .user.account_id == $me)] | length > 0 | tostring),
        ((.title // "") | gsub("[\u001f\n]"; " ")),
        ((.source.branch.name // "") | gsub("[\u001f\n]"; " ")) ]
    | join("\u001f")' 2>/dev/null) || { echo "#$id skip: unreadable record"; skip=$((skip + 1)); continue; }
  IFS=$'\037' read -r created author nick builds mine title branch <<EOF
$facts
EOF
  short=$(printf '%s' "$title" | cut -c1-90)
  if [ "$author" != "$BOTID" ] || { [ -n "$BOT" ] && [ "$nick" != "$BOT" ]; }; then
    echo "#$id skip: not authored by the bot"; skip=$((skip + 1)); continue
  fi
  hay=$(printf '%s %s' "$title" "$branch" | tr '[:upper:]' '[:lower:]')
  hit=
  for w in "${SKIP_WORDS[@]+"${SKIP_WORDS[@]}"}"; do
    case "$hay" in *"$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]')"*) hit=$w; break ;; esac
  done
  [ -z "$hit" ] || { echo "#$id skip: contains \"$hit\"  $short"; skip=$((skip + 1)); continue; }
  [ "$created" -ge "$cutoff" ] 2>/dev/null || { echo "#$id skip: older than $DAYS days"; skip=$((skip + 1)); continue; }
  [ "$builds" = green ] || { echo "#$id skip: builds at head $builds  $short"; skip=$((skip + 1)); continue; }
  [ "$mine" != true ] || { echo "#$id skip: already approved by you"; skip=$((skip + 1)); continue; }
  if [ "$APPLY" = 1 ]; then
    if fm_pr_bitbucket_twg pull-requests approve "$id" --workspace "$WS" --repo "$REPO" >/dev/null; then
      echo "#$id APPROVED  $short"; ok=$((ok + 1))
    else
      echo "#$id approve FAILED  $short"
    fi
  else
    echo "#$id would approve  $short"; ok=$((ok + 1))
  fi
done
if [ "$APPLY" = 1 ]; then
  echo "--- approved: $ok, skipped: $skip"
else
  echo "--- eligible: $ok, skipped: $skip  (dry run; use --apply)"
fi
