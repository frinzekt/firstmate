#!/usr/bin/env bash
# tests/fm-login-path.test.sh - the worker-launch PATH refresh
# (bin/fm-login-path-lib.sh) rebuilds PATH from a fresh login shell, bounded,
# and falls back to the inherited PATH with one warning line.
#
# Every case uses a stub login shell named through FM_SPAWN_LOGIN_SHELL, so no
# real profile runs. The last case drives the real bin/fm-spawn.sh against a
# fake pane and checks the PATH export the pane received.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-login-path)

# stub_shell <path> <body>: an executable stub login shell.
stub_shell() {
  printf '#!/bin/sh\n%s\n' "$2" > "$1"
  chmod +x "$1"
}

# refresh_in <inherited-PATH> [env assignments...]: run fm_login_path_refresh
# in a fresh bash and print "refreshed=<0|1>", then "path=<PATH>", then the
# warning lines on stderr folded into stdout.
refresh_in() {
  local inherited=$1
  shift
  env "$@" bash -c '
    . "$1/bin/fm-timeout-lib.sh"
    . "$1/bin/fm-login-path-lib.sh"
    PATH=$2
    fm_login_path_refresh 2>&1
    printf "refreshed=%s\n" "$FM_LOGIN_PATH_REFRESHED"
    printf "path=%s\n" "$PATH"
    /bin/sh -c "printf \"exported=%s\n\" \"\$PATH\""
  ' _ "$ROOT" "$inherited"
}

test_refresh_puts_the_login_path_first_and_drops_removed_dirs() {
  local dir="$TMP_ROOT/merge" out
  mkdir -p "$dir/new-node/bin" "$dir/kept"
  stub_shell "$dir/shell" "echo 'profile banner on stdout'
printf '\\n__FM_LOGIN_PATH__=%s\\n' '$dir/new-node/bin:/usr/bin:/bin'"
  out=$(refresh_in "$dir/old-node/bin:$dir/kept:/usr/bin" FM_SPAWN_LOGIN_PATH=1 FM_SPAWN_LOGIN_SHELL="$dir/shell")
  assert_contains "$out" "refreshed=1" "a working login shell should refresh PATH"
  assert_contains "$out" "path=$dir/new-node/bin:/usr/bin:/bin:$dir/kept" \
    "the login PATH should come first, then inherited dirs that still exist, without duplicates"
  assert_contains "$out" "exported=$dir/new-node/bin:/usr/bin:/bin:$dir/kept" \
    "the refreshed PATH should be exported to child processes"
  assert_not_contains "$out" "old-node" "a removed inherited directory should drop out"
  assert_not_contains "$out" "warning:" "a successful refresh should print no warning"
  pass "refresh puts the login shell's PATH first and drops removed inherited directories"
}

test_probe_runs_a_cleared_interactive_login_shell() {
  local dir="$TMP_ROOT/cleared" out
  mkdir -p "$dir"
  # The stub reports what it saw as its PATH answer, so the assertion reads
  # exactly the environment and arguments the probe gave it.
  stub_shell "$dir/shell" "printf '\\n__FM_LOGIN_PATH__=/seen:%s:%s:%s:%s\\n' \"\$PATH\" \"\${FM_STALE_MARKER-unset}\" \"\$TERM\" \"\$*\""
  out=$(FM_STALE_MARKER=leaked FM_SPAWN_LOGIN_SHELL="$dir/shell" bash -c '
    . "$1/bin/fm-timeout-lib.sh"; . "$1/bin/fm-login-path-lib.sh"; fm_login_path_probe' _ "$ROOT")
  assert_equals "/seen:/usr/bin:/bin:/usr/sbin:/sbin:unset:dumb:-ilc printf \"\\n%s%s\\n\" \"__FM_LOGIN_PATH__=\" \"\$PATH\"" "$out" \
    "the probe should start an interactive login shell from a cleared environment with only the base PATH"
  pass "the probe runs an interactive login shell in a cleared environment"
}

test_failures_keep_the_inherited_path_with_one_warning() {
  local dir="$TMP_ROOT/fail" out case_name
  mkdir -p "$dir"
  stub_shell "$dir/slow" 'sleep 5'
  stub_shell "$dir/silent" 'echo no marker here; exit 3'
  stub_shell "$dir/relative" "printf '\\n__FM_LOGIN_PATH__=bin:/usr/bin\\n'"
  for case_name in slow silent relative missing; do
    out=$(refresh_in "/usr/bin:/bin" FM_SPAWN_LOGIN_PATH=1 FM_SPAWN_LOGIN_PATH_TIMEOUT=1 \
      FM_SPAWN_LOGIN_SHELL="$dir/$case_name")
    assert_contains "$out" "refreshed=0" "$case_name: a failed probe should not mark PATH refreshed"
    assert_contains "$out" "path=/usr/bin:/bin" "$case_name: a failed probe should keep the inherited PATH"
    [ "$(printf '%s\n' "$out" | grep -c '^warning: login-shell PATH refresh failed (')" = 1 ] \
      || fail "$case_name: a failed probe should print exactly one warning line: $out"
  done
  assert_contains "$(refresh_in /usr/bin FM_SPAWN_LOGIN_PATH=1 FM_SPAWN_LOGIN_PATH_TIMEOUT=1 FM_SPAWN_LOGIN_SHELL="$dir/slow")" \
    "did not answer within 1s" "a slow shell should be reported as hitting the bound"
  pass "a slow, silent, malformed, or missing login shell keeps the inherited PATH with one warning"
}

test_opt_out_runs_no_shell() {
  local dir="$TMP_ROOT/optout" out
  mkdir -p "$dir"
  stub_shell "$dir/shell" "touch '$dir/ran'; printf '\\n__FM_LOGIN_PATH__=/elsewhere\\n'"
  out=$(refresh_in "/usr/bin:/bin" FM_SPAWN_LOGIN_PATH=0 FM_SPAWN_LOGIN_SHELL="$dir/shell")
  assert_contains "$out" "refreshed=0" "the opt-out should leave PATH unrefreshed"
  assert_contains "$out" "path=/usr/bin:/bin" "the opt-out should keep the inherited PATH"
  assert_absent "$dir/ran" "the opt-out should not start the login shell"
  pass "FM_SPAWN_LOGIN_PATH=0 starts no login shell and keeps PATH"
}

test_spawn_exports_the_refreshed_path_into_the_pane() {
  local case_dir="$TMP_ROOT/spawn" home proj wt fakebin panelog launchlog out status line
  home="$case_dir/home" proj="$case_dir/project" wt="$case_dir/wt"
  panelog="$case_dir/pane.log" launchlog="$case_dir/launch.log"
  mkdir -p "$case_dir/fresh tools"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" wt-login-path
  fm_test_spawn_brief "$home" login-path-a1
  stub_shell "$case_dir/shell" "printf '\\n__FM_LOGIN_PATH__=%s\\n' '$case_dir/fresh tools:/usr/bin:/bin'"
  : > "$panelog"
  : > "$launchlog"
  out=$(FM_SPAWN_LOGIN_PATH=1 FM_SPAWN_LOGIN_SHELL="$case_dir/shell" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" login-path-a1 "$proj" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "spawn with a refreshed PATH should succeed: $out"
  line=$(grep '^export PATH=' "$panelog")
  [ "$(printf '%s\n' "$line" | grep -c .)" = 1 ] || fail "the pane should receive exactly one PATH export: $(cat "$panelog")"
  # Evaluate the export the pane received: it must start with the login
  # shell's entries, quoted so a space survives, and keep the fixture tools.
  out=$(env -i /bin/sh -c "$line; printf '%s' \"\$PATH\"")
  case "$out" in
    "$case_dir/fresh tools:/usr/bin:/bin:"*"$fakebin"*) ;;
    *) fail "the pane PATH should start with the login shell's PATH and keep inherited dirs: $out" ;;
  esac
  pass "a real spawn exports the refreshed PATH into the pane before launch"
}

fm_test_run \
  test_refresh_puts_the_login_path_first_and_drops_removed_dirs \
  test_probe_runs_a_cleared_interactive_login_shell \
  test_failures_keep_the_inherited_path_with_one_warning \
  test_opt_out_runs_no_shell \
  test_spawn_exports_the_refreshed_path_into_the_pane
