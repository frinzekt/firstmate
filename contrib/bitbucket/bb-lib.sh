#!/usr/bin/env bash
# bb-lib.sh - shared helpers for the contrib/bitbucket scripts; sourced, never run.
#
# Resolves the firstmate code root this directory ships in (BB_FM_ROOT), so the
# scripts call that root's bin/ tools and reuse bin/fm-pr-lib.sh's Bitbucket
# readers rather than a second copy. The home is always the caller's FM_HOME,
# which must name an existing directory: nothing here defaults to a path.

BB_CONTRIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BB_FM_ROOT="$(cd "$BB_CONTRIB_DIR/../.." && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$BB_FM_ROOT/bin/fm-pr-lib.sh"

bb_die() {  # <exit-status> <message>
  printf '%s: %s\n' "${BB_PROG:-bitbucket}" "$2" >&2
  exit "$1"
}

# FM_HOME must be set to an existing directory; it is never guessed.
bb_require_home() {
  [ -n "${FM_HOME:-}" ] || bb_die 2 "FM_HOME must name the firstmate home"
  [ -d "$FM_HOME" ] || bb_die 2 "FM_HOME '$FM_HOME' is not a directory"
  FM_HOME=$(cd "$FM_HOME" && pwd)
  export FM_HOME
}

# Workspace and repository slugs, as bitbucket.org writes them.
bb_require_slugs() {  # <workspace> <repo>
  [ -n "$1" ] || bb_die 2 "a workspace is required (--workspace or BB_WORKSPACE)"
  [ -n "$2" ] || bb_die 2 "a repository is required (--repo or BB_REPO)"
  fm_pr_bitbucket_segment_valid "$1" || bb_die 2 "invalid workspace slug '$1'"
  fm_pr_bitbucket_segment_valid "$2" || bb_die 2 "invalid repository slug '$2'"
}

bb_require_number() {  # <what> <value>
  case "$2" in
    ''|0*|*[!0-9]*) bb_die 2 "$1 must be a positive integer, got '$2'" ;;
  esac
}

bb_require_tools() {  # <tool>...
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || bb_die 1 "$tool is required on PATH"
  done
}

# The build verdict at one pull request's full head, from its build statuses:
# NONE when no status reported at the head, FAILED when any status there failed
# or stopped, RUNNING when any is still in progress, otherwise GREEN. Prints
# "<verdict> <head>", or "UNKNOWN " when the head cannot be resolved.
# shellcheck disable=SC2016 # jq program text, not shell expansions.
bb_ci_verdict_from_json() {  # <pr-json>
  printf '%s' "$1" | jq -r "$FM_PR_BITBUCKET_JQ_DEFS"'
    bb_head as $h
    | if $h == "" then "UNKNOWN "
      else
        [bb_statuses[] | select((.commit.hash // "") == $h) | .state] as $s
        | (if ($s | length) == 0 then "NONE"
           elif any($s[]; . == "FAILED" or . == "STOPPED") then "FAILED"
           elif any($s[]; . != "SUCCESSFUL") then "RUNNING"
           else "GREEN" end) + " " + $h
      end' 2>/dev/null
}
