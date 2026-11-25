#!/usr/bin/env bash
# fm-login-path-lib.sh - the single owner of the worker-launch PATH refresh.
#
# Sourced, never executed. Requires bin/fm-timeout-lib.sh (fm_run_timed).
#
# A long-running firstmate keeps the PATH it started with, so a tool installed
# or upgraded since then (for example a Node upgrade under nvm) leaves that PATH
# naming a removed or outdated directory. bin/fm-spawn.sh calls
# fm_login_path_refresh once per worker launch so the launch, and the worker it
# starts, see PATH as the captain's shell builds it now.
#
#   fm_login_path_probe
#       Prints the PATH a fresh interactive login shell builds, on one line.
#       The shell is FM_SPAWN_LOGIN_SHELL, else SHELL, and must be an absolute
#       executable path. It starts from a cleared environment that keeps only
#       HOME, USER, LOGNAME, SHELL, TERM=dumb, and the base PATH
#       /usr/bin:/bin:/usr/sbin:/sbin, so no inherited, possibly stale PATH
#       entry survives into the answer. It runs as `<shell> -ilc` because
#       many profiles set up version managers only for interactive shells.
#       Stdin is /dev/null, stderr is discarded, and the answer is read from
#       one marker line so profile output on stdout cannot be mistaken for it.
#       The run is bounded by FM_SPAWN_LOGIN_PATH_TIMEOUT seconds (a positive
#       integer, default 10). Returns non-zero and prints one reason on stderr
#       when the shell is unusable, the bound is hit, the shell fails, or the
#       answer is empty or does not start with an absolute directory.
#
#   fm_login_path_refresh
#       With FM_SPAWN_LOGIN_PATH=0, does nothing. Otherwise sets and exports
#       PATH to the probe's answer followed by every inherited entry that is
#       still an existing directory and is not already present, so a removed
#       directory drops out and a deliberate inherited addition stays
#       reachable after the shell's own entries. On success it sets
#       FM_LOGIN_PATH_REFRESHED=1. On failure it prints one
#       "warning: login-shell PATH refresh failed (...)" line on stderr, keeps
#       the inherited PATH, and sets FM_LOGIN_PATH_REFRESHED=0. It always
#       returns 0, so a launch is never blocked by this refresh.
#
# The test library (tests/lib.sh) exports FM_SPAWN_LOGIN_PATH=0 so fixture
# PATH stubs keep precedence; a test of this refresh sets it back explicitly.
set -u

FM_LOGIN_PATH_MARKER=__FM_LOGIN_PATH__=
# Read by the sourcing script (bin/fm-spawn.sh).
# shellcheck disable=SC2034
FM_LOGIN_PATH_REFRESHED=0

fm_login_path_probe() {
  local shell=${FM_SPAWN_LOGIN_SHELL:-${SHELL:-}} bound=${FM_SPAWN_LOGIN_PATH_TIMEOUT:-10} out rc answer
  case "$bound" in ''|0|*[!0-9]*) bound=10 ;; esac
  case "$shell" in
    /*) [ -x "$shell" ] && [ ! -d "$shell" ] || { echo "login shell $shell is not executable" >&2; return 1; } ;;
    *) echo "no absolute login shell in SHELL" >&2; return 1 ;;
  esac
  # shellcheck disable=SC2016  # $PATH expands in the login shell, not here.
  out=$(fm_run_timed "$bound" /usr/bin/env -i HOME="${HOME:-}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
    SHELL="$shell" TERM=dumb PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$shell" -ilc 'printf "\n%s%s\n" "__FM_LOGIN_PATH__=" "$PATH"' </dev/null 2>/dev/null)
  rc=$?
  if fm_timed_out "$rc"; then
    echo "$shell did not answer within ${bound}s" >&2
    return 1
  fi
  answer=$(printf '%s\n' "$out" | sed -n "s/^$FM_LOGIN_PATH_MARKER//p" | tail -n 1 | tr -d '\r')
  if [ -z "$answer" ]; then
    echo "$shell exited $rc without reporting PATH" >&2
    return 1
  fi
  case "$answer" in
    /*) ;;
    *) echo "$shell reported a PATH that does not start with an absolute directory" >&2; return 1 ;;
  esac
  printf '%s\n' "$answer"
}

fm_login_path_refresh() {
  local fresh err_file reason merged entry
  FM_LOGIN_PATH_REFRESHED=0
  [ "${FM_SPAWN_LOGIN_PATH:-1}" != 0 ] || return 0
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-login-path.XXXXXX" 2>/dev/null) || err_file=/dev/null
  if ! fresh=$(fm_login_path_probe 2>"$err_file"); then
    reason=$(head -n 1 "$err_file" 2>/dev/null)
    [ "$err_file" = /dev/null ] || rm -f "$err_file"
    echo "warning: login-shell PATH refresh failed (${reason:-unknown reason}); launching with the inherited PATH" >&2
    return 0
  fi
  [ "$err_file" = /dev/null ] || rm -f "$err_file"
  merged=$fresh
  local IFS=:
  for entry in ${PATH:-}; do
    [ -n "$entry" ] && [ -d "$entry" ] || continue
    case ":$merged:" in *":$entry:"*) continue ;; esac
    merged="$merged:$entry"
  done
  PATH=$merged
  export PATH
  FM_LOGIN_PATH_REFRESHED=1
  return 0
}
