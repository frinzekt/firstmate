#!/usr/bin/env bash
# tests/fm-spawn-orca-worktree.test.sh - regression coverage for the
# backend=orca carve-outs in bin/fm-spawn.sh's worktree-entry proof (#4991,
# bacadc4).
#
# spawn_current_path (bin/fm-spawn.sh) has no `orca` case, because Orca hands
# back a terminal that is already bound to the worktree it just created -
# there is no shared pane whose cwd firstmate must poll for. Without an
# explicit skip, spawn_assert_agent_worktree's post-launch proof would poll
# spawn_current_path in a loop, read nothing but empty output every time, and
# hard-refuse EVERY Orca launch once its 20-read deadline elapsed. This test
# spawns a real (fake-Orca-backed) task and asserts it succeeds and records
# the worktree Orca actually created, proving the skip does not just avoid an
# error but lets a genuine Orca launch complete.
#
# The relaunch-side carve-out at the `[ "$RELAUNCH" -eq 1 ] &&
# [ "$BACKEND" = orca ]` branch is reached only through the Orca reclaim: the
# recorded terminal must be proven gone (bin/fm-control-lib.sh
# fm_control_endpoint_absence_verdict), and a stateful fake Orca below pins the
# rebind, the refusals, and the adoption of a worktree a redeployed runtime
# forgot.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-orca-worktree)

# make_orca_fakebin <dir>: a fake `orca` CLI that performs a REAL `git
# worktree add` for `worktree create` (so spawn_worktree_isolated's checks are
# exercised against a genuine, isolated worktree) and answers every other
# lifecycle call (status/repo/terminal/send) with the minimal JSON shape
# bin/backends/orca.sh's node-based parsers accept.
make_orca_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
DIR="${FM_TEST_ORCA_DIR:?}"
case "$1 $2" in
  "status --json")
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    exit 0
    ;;
  "repo show")
    exit 1
    ;;
  "repo add")
    printf '{"ok":true,"result":{"repo":{"id":"repo1"}}}\n'
    exit 0
    ;;
  "worktree create")
    name=
    prev=
    for a in "$@"; do
      [ "$prev" = --name ] && name=$a
      prev=$a
    done
    wt="$DIR/orca-worktrees/$name"
    mkdir -p "$DIR/orca-worktrees"
    git -C "$DIR/project" worktree add --quiet -b "orca-$name" "$wt" >&2 || exit 1
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' "$name" "$wt"
    exit 0
    ;;
  "terminal create")
    printf '{"ok":true,"result":{"terminal":{"handle":"term-1"}}}\n'
    exit 0
    ;;
  "terminal close")
    touch "$DIR/terminal-closed"
    exit 0
    ;;
  "terminal send")
    if [ -n "${FM_TEST_ORCA_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        [ "$prev" != --text ] || printf '%s\n' "$a" >> "$FM_TEST_ORCA_LOG"
        prev=$a
      done
    fi
    # FM_TEST_ORCA_HOLD_TEXT holds the source-text delivery open after the
    # text arrived, so a test can interrupt the spawn before it sends Enter.
    if [ "${FM_TEST_ORCA_HOLD_TEXT:-0}" = 1 ]; then
      case "$*" in
        */launch.*)
          touch "$DIR/text-delivered"
          i=0
          while [ ! -e "$DIR/release" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
          ;;
      esac
    fi
    if [ "${FM_TEST_ORCA_SEND_FAIL:-0}" = 1 ]; then
      case "$*" in */launch.*) exit 1 ;; esac
    fi
    # FM_TEST_ORCA_CONSUME acts as the pane: it captures the staged file and its
    # mode, then unlinks it as the real launch line does, optionally after a delay.
    if [ "${FM_TEST_ORCA_CONSUME:-0}" = 1 ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = --text ]; then
          case "$a" in
            *"'"*/launch.*)
              f=${a#*"'"}; f=${f%%"'"*}
              (
                sleep "${FM_TEST_ORCA_CONSUME_DELAY:-0}"
                { stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f"; } > "$f.mode"
                cp "$f" "$f.copy" && rm -f "$f"
              ) >/dev/null 2>&1 &
              ;;
          esac
        fi
        prev=$a
      done
    fi
    # FM_TEST_ORCA_RM_FAIL acts as a pane that sources the staged file with an
    # rm that always fails, then keeps running.
    if [ "${FM_TEST_ORCA_RM_FAIL:-0}" = 1 ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = --text ]; then
          case "$a" in
            *"'"*/launch.*)
              f=${a#*"'"}; f=${f%%"'"*}
              mkdir -p "$DIR/rmfail"
              printf '#!/bin/sh\nexit 1\n' > "$DIR/rmfail/rm"
              chmod +x "$DIR/rmfail/rm"
              # shellcheck disable=SC2016 # The pane shell expands its own arguments.
              PATH="$DIR/rmfail:$PATH" sh -c '. "$1"; echo "source-status=$?"; echo SHELL-STILL-ALIVE' _ "$f" > "$DIR/pane.out" 2>&1 &
              ;;
          esac
        fi
        prev=$a
      done
    fi
    printf '{"ok":true}\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

test_orca_fresh_spawn_enters_the_worktree_it_created() {
  local case_dir home id=orca-fresh-a1 fb out status wt_recorded
  case_dir="$TMP_ROOT/fresh"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_init_commit "$case_dir/project"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca-backed spawn for $id.

## Firstmate spec
Confirm the launch enters the worktree Orca created for it.
EOF
  fb=$(make_orca_fakebin "$case_dir")

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?

  expect_code 0 "$status" "an Orca-backed spawn should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"$'\n'"$out"
  wt_recorded=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ -n "$wt_recorded" ] || fail "meta did not record a worktree"
  [ -d "$wt_recorded" ] || fail "the recorded worktree '$wt_recorded' does not exist"
  [ "$(cd "$wt_recorded" && git rev-parse --show-toplevel)" = "$(cd "$wt_recorded" && pwd -P)" ] \
    || fail "the recorded worktree is not the isolated worktree Orca created"
  pass "an Orca-backed fresh spawn enters the worktree Orca created for it, instead of hard-refusing on the post-launch proof"
}

# make_orca_reclaim_fakebin <dir>: a stateful fake `orca` for the relaunch
# reclaim. State files under <dir>/orca:
#   runtime-down     `orca status` reports an unreachable runtime
#   known-wt         the worktree id this runtime knows (absent: none)
#   repo-registered  the project is registered (absent: `repo show` fails)
#   live             live terminal handles, one per line
#   list-fails       `terminal list` exits non-zero
# A path selector resolves the recorded worktree as "repo2::<path>" once the
# project is registered, which is how a redeployed runtime names it. Every
# call is logged to <dir>/orca/log.
make_orca_reclaim_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  mkdir -p "$dir/orca"
  : > "$dir/orca/live"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
S="${FM_TEST_ORCA_DIR:?}/orca"
printf '%s\n' "$*" >> "$S/log"
arg() {  # <flag>: the value after <flag>
  local prev= a
  for a in "$@"; do
    [ "$prev" = "$FLAG" ] && { printf '%s' "$a"; return 0; }
    prev=$a
  done
}
meta='"_meta":{"runtimeId":"rt-1"}'
case "$1 $2" in
  "status --json")
    if [ -e "$S/runtime-down" ]; then
      printf '{"ok":false,"error":{"code":"runtime_unavailable","message":"down"}}\n'
      exit 1
    fi
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    ;;
  "repo show")
    [ -e "$S/repo-registered" ] || exit 1
    printf '{"ok":true,"result":{"repo":{"id":"repo2"}}}\n'
    ;;
  "repo add")
    touch "$S/repo-registered"
    printf '{"ok":true,"result":{"repo":{"id":"repo2"}}}\n'
    ;;
  "worktree show")
    sel=$(FLAG=--worktree arg "$@")
    case "$sel" in
      id:*)
        id=${sel#id:}
        if [ -e "$S/known-wt" ] && [ "$id" = "$(cat "$S/known-wt")" ]; then
          printf '{"ok":true,"result":{"worktree":{"id":"%s","path":"%s","hostId":"local"}},%s}\n' "$id" "${id#*::}" "$meta"
          exit 0
        fi
        ;;
      path:*)
        p=${sel#path:}
        if [ -e "$S/repo-registered" ] && [ -d "$p" ]; then
          printf 'repo2::%s' "$p" > "$S/known-wt"
          printf '{"ok":true,"result":{"worktree":{"id":"repo2::%s","path":"%s","hostId":"local"}},%s}\n' "$p" "$p" "$meta"
          exit 0
        fi
        ;;
    esac
    printf '{"ok":false,"error":{"code":"selector_not_found","message":"selector_not_found"},%s}\n' "$meta"
    exit 1
    ;;
  "terminal list")
    [ ! -e "$S/list-fails" ] || exit 1
    rows=
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      rows="$rows${rows:+,}{\"handle\":\"$h\"}"
    done < "$S/live"
    printf '{"ok":true,"result":{"terminals":[%s],"hostScope":{"hostIds":["local"],"omittedHostIds":[]},"truncated":false},%s}\n' "$rows" "$meta"
    ;;
  "terminal show")
    h=$(FLAG=--terminal arg "$@")
    if grep -qxF "$h" "$S/live"; then
      printf '{"ok":true,"result":{"terminal":{"handle":"%s"}},%s}\n' "$h" "$meta"
      exit 0
    fi
    printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal_handle_stale"},%s}\n' "$meta"
    exit 1
    ;;
  "terminal create")
    printf '%s\n' term-new >> "$S/live"
    printf '%s\n' "$(FLAG=--worktree arg "$@")" > "$S/created-in"
    printf '{"ok":true,"result":{"terminal":{"handle":"term-new"}}}\n'
    ;;
  "terminal read")
    printf '{"ok":true,"result":{"tail":["$ "]}}\n'
    ;;
  "terminal close")
    h=$(FLAG=--terminal arg "$@")
    grep -vxF "$h" "$S/live" > "$S/live.tmp" || true
    mv "$S/live.tmp" "$S/live"
    printf '{"ok":true}\n'
    ;;
  "terminal send")
    printf '{"ok":true}\n'
    ;;
  "worktree create")
    touch "$S/worktree-created"
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

# orca_reclaim_case <name> <id>: a recorded Orca ship task whose worktree is
# a real linked git worktree of its project and whose recorded terminal is
# term-old. Sets RC_DIR, RC_HOME, RC_WT, RC_PROJ, RC_FB.
orca_reclaim_case() {
  local name=$1 id=$2
  RC_DIR="$TMP_ROOT/$name"
  RC_HOME="$RC_DIR/home"
  RC_PROJ="$RC_DIR/proj"
  RC_WT="$RC_DIR/wt"
  mkdir -p "$RC_HOME/data/$id" "$RC_HOME/projects" "$RC_HOME/state" "$RC_HOME/config"
  touch "$RC_HOME/state/.last-watcher-beat"
  printf 'manual\n' > "$RC_HOME/config/backlog-backend"
  fm_git_worktree "$RC_PROJ" "$RC_WT" "task-$id"
  RC_PROJ=$(cd "$RC_PROJ" && pwd -P)
  RC_WT=$(cd "$RC_WT" && pwd -P)
  cat > "$RC_HOME/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca reclaim for $id.

## Firstmate spec
Bring the worker back in the recorded worktree.
EOF
  {
    echo "window=fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$RC_WT"
    echo "project=$RC_PROJ"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "backend=orca"
    echo "orca_worktree_id=repo1::$RC_WT"
    echo "terminal=term-old"
  } > "$RC_HOME/state/$id.meta"
  RC_FB=$(make_orca_reclaim_fakebin "$RC_DIR")
  printf 'repo1::%s' "$RC_WT" > "$RC_DIR/orca/known-wt"
  touch "$RC_DIR/orca/repo-registered"
}

orca_reclaim_run() {  # <script> <args...>
  local script=$1
  shift
  mkdir -p "$RC_DIR/user-home"
  FM_ROOT_OVERRIDE='' FM_HOME="$RC_HOME" HOME="$RC_DIR/user-home" \
    FM_STATE_OVERRIDE="$RC_HOME/state" FM_DATA_OVERRIDE="$RC_HOME/data" \
    FM_PROJECTS_OVERRIDE="$RC_HOME/projects" FM_CONFIG_OVERRIDE="$RC_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$RC_DIR" PATH="$RC_FB:$PATH" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$script" "$@" 2>&1
}

orca_meta() {  # <id> <key>
  grep "^$2=" "$RC_HOME/state/$1.meta" | tail -1 | cut -d= -f2-
}

test_orca_relaunch_rebinds_a_terminal_proven_gone() {
  local id=orca-gone-a1 out status before
  orca_reclaim_case gone "$id"
  before=$(git -C "$RC_WT" rev-parse HEAD)
  printf 'uncommitted\n' > "$RC_WT/dirty.txt"
  out=$(orca_reclaim_run "$SPAWN" "$id" --relaunch)
  status=$?
  expect_code 0 "$status" "a relaunch whose Orca terminal is proven gone should succeed"$'\n'"$out"
  [ "$(orca_meta "$id" terminal)" = term-new ] || fail "the record did not rebind terminal= to the new terminal: $(orca_meta "$id" terminal)"
  [ "$(orca_meta "$id" orca_worktree_id)" = "repo1::$RC_WT" ] || fail "the worktree id moved: $(orca_meta "$id" orca_worktree_id)"
  [ "$(orca_meta "$id" worktree)" = "$RC_WT" ] || fail "the recorded worktree moved"
  [ "$(orca_meta "$id" endpoint_task_id)" = "$id" ] || fail "the task identity moved"
  [ "$(cat "$RC_DIR/orca/created-in")" = "id:repo1::$RC_WT" ] || fail "the new terminal was not opened in the recorded worktree"
  [ ! -e "$RC_DIR/orca/worktree-created" ] || fail "a relaunch created a new Orca worktree"
  [ "$(git -C "$RC_WT" rev-parse HEAD)" = "$before" ] || fail "the relaunch moved the worktree HEAD"
  assert_contains "$(cat "$RC_WT/dirty.txt")" uncommitted "the relaunch lost an uncommitted change"
  pass "Orca relaunch: a terminal proven gone gets one fresh terminal in the recorded worktree and the record rebinds to it"
}

test_orca_relaunch_refuses_a_live_terminal() {
  local id=orca-live-a2 out status before
  orca_reclaim_case live "$id"
  printf 'term-old\n' > "$RC_DIR/orca/live"
  before=$(cat "$RC_HOME/state/$id.meta")
  out=$(orca_reclaim_run "$SPAWN" "$id" --relaunch)
  status=$?
  expect_code 1 "$status" "a relaunch over a live Orca terminal must refuse"$'\n'"$out"
  assert_contains "$out" "still live" "the refusal should say the recorded terminal is still live"
  [ "$(cat "$RC_HOME/state/$id.meta")" = "$before" ] || fail "a refused relaunch changed the record"
  grep -q '^terminal create' "$RC_DIR/orca/log" && fail "a refused relaunch created a terminal"
  pass "Orca relaunch: a recorded terminal that is still live refuses with the record untouched"
}

test_orca_relaunch_refuses_an_unreachable_runtime() {
  local id=orca-down-a3 out status
  orca_reclaim_case down "$id"
  touch "$RC_DIR/orca/runtime-down"
  out=$(orca_reclaim_run "$SPAWN" "$id" --relaunch)
  status=$?
  expect_code 1 "$status" "a relaunch with an unreachable Orca runtime must refuse"$'\n'"$out"
  [ "$(orca_meta "$id" terminal)" = term-old ] || fail "a refused relaunch rebound the record"
  grep -q '^terminal create' "$RC_DIR/orca/log" && fail "a refused relaunch created a terminal"
  pass "Orca relaunch: an unreachable runtime is never read as a gone terminal"
}

test_orca_relaunch_refuses_an_unreadable_inventory() {
  local id=orca-list-a4 out status
  orca_reclaim_case listfail "$id"
  touch "$RC_DIR/orca/list-fails"
  out=$(orca_reclaim_run "$SPAWN" "$id" --relaunch)
  status=$?
  expect_code 1 "$status" "a relaunch whose terminal inventory fails must refuse"$'\n'"$out"
  grep -q '^terminal create' "$RC_DIR/orca/log" && fail "a refused relaunch created a terminal"
  pass "Orca relaunch: a failed terminal inventory refuses rather than proving absence"
}

test_orca_relaunch_refuses_a_missing_worktree() {
  local id=orca-nowt-a5 out status
  orca_reclaim_case nowt "$id"
  rm -f "$RC_DIR/orca/known-wt"
  git -C "$RC_PROJ" worktree remove --force "$RC_WT"
  out=$(orca_reclaim_run "$SPAWN" "$id" --relaunch)
  status=$?
  expect_code 1 "$status" "a relaunch whose worktree is gone must refuse"$'\n'"$out"
  grep -q '^terminal create' "$RC_DIR/orca/log" && fail "a refused relaunch created a terminal"
  [ ! -e "$RC_DIR/orca/worktree-created" ] || fail "a refused relaunch created a worktree"
  pass "Orca relaunch: a recorded worktree that no longer exists refuses and never creates a new one"
}

test_orca_relaunch_adopts_the_worktree_a_redeployed_runtime_forgot() {
  local id=orca-adopt-a6 out status
  orca_reclaim_case adopt "$id"
  # A redeployed runtime: an empty registry, the project unregistered, and
  # the git worktree still on disk.
  rm -f "$RC_DIR/orca/known-wt" "$RC_DIR/orca/repo-registered"
  out=$(orca_reclaim_run "$SPAWN" "$id" --relaunch)
  status=$?
  expect_code 0 "$status" "a relaunch should adopt the on-disk worktree a redeployed runtime forgot"$'\n'"$out"
  grep -q '^repo add' "$RC_DIR/orca/log" || fail "the project was not registered again"
  [ "$(orca_meta "$id" orca_worktree_id)" = "repo2::$RC_WT" ] || fail "the record did not rebind the worktree id: $(orca_meta "$id" orca_worktree_id)"
  [ "$(orca_meta "$id" terminal)" = term-new ] || fail "the record did not rebind terminal="
  [ ! -e "$RC_DIR/orca/worktree-created" ] || fail "an adoption created a new Orca worktree"
  pass "Orca relaunch: a worktree a redeployed runtime forgot is re-registered by path and adopted, never re-created"
}

test_orca_relaunch_refuses_to_adopt_a_non_worktree_path() {
  local id=orca-noadopt-a7 out status
  orca_reclaim_case noadopt "$id"
  rm -f "$RC_DIR/orca/known-wt" "$RC_DIR/orca/repo-registered"
  # The recorded path is a plain directory now, not a worktree of the project.
  git -C "$RC_PROJ" worktree remove --force "$RC_WT"
  mkdir -p "$RC_WT"
  out=$(orca_reclaim_run "$SPAWN" "$id" --relaunch)
  status=$?
  expect_code 1 "$status" "a relaunch must not adopt a path that is not a worktree of the project"$'\n'"$out"
  grep -q '^repo add' "$RC_DIR/orca/log" && fail "an unadoptable path still registered the project"
  grep -q '^terminal create' "$RC_DIR/orca/log" && fail "a refused adoption created a terminal"
  pass "Orca relaunch: a forgotten worktree id over a path that is not a linked worktree of the project refuses"
}

test_orca_control_relaunch_reclaims_and_keeps_exit_refusing() {
  local id=orca-ctl-a8 out status
  orca_reclaim_case control "$id"
  out=$(orca_reclaim_run "$ROOT/bin/fm-control.sh" "$id" exit)
  status=$?
  expect_code 1 "$status" "exit on Orca stays refused"$'\n'"$out"
  assert_contains "$out" "no recovery-grade agent-state classifier" "exit on Orca should keep its classifier refusal"
  printf 'term-old\n' > "$RC_DIR/orca/live"
  out=$(orca_reclaim_run "$ROOT/bin/fm-control.sh" "$id" relaunch --note "box restarted")
  status=$?
  expect_code 1 "$status" "fm-control relaunch over a live Orca terminal must refuse"$'\n'"$out"
  assert_contains "$out" "refusing before anything is touched" "the live-terminal refusal should precede the checkpoint"
  assert_not_contains "$(cat "$RC_HOME/data/$id/brief.md")" "box restarted" "a refused relaunch appended its note"
  : > "$RC_DIR/orca/live"
  out=$(orca_reclaim_run "$ROOT/bin/fm-control.sh" "$id" relaunch --note "box restarted")
  status=$?
  expect_code 0 "$status" "fm-control relaunch should reclaim a gone Orca terminal"$'\n'"$out"
  assert_contains "$out" "relaunched $id" "the relaunch should report success"
  [ "$(orca_meta "$id" terminal)" = term-new ] || fail "fm-control relaunch did not rebind terminal="
  assert_contains "$(cat "$RC_HOME/data/$id/brief.md")" "box restarted" "the progress note did not reach the brief"
  [ "$(grep '^exit_result=' "$RC_HOME/state/$id.control-relaunch" | tail -1 | cut -d= -f2-)" = endpoint-gone ] \
    || fail "the journal should record that the endpoint was already gone"
  pass "Orca control relaunch: refuses a live terminal before the checkpoint, reclaims a gone one with the note, exit unchanged"
}

# Source values are synthetic and deliberately include shell syntax and trailing
# newlines. Removing the source overlay, ambient clearing, or quoting breaks
# these executions of the real staged spawn command.
test_orca_launch_uses_controlled_tmux_environment() {
  local setting case_dir home id fb out status staged staged_content result expected value pane_shell failbin delivered
  for setting in absent enabled empty unavailable malformed nonregular missing sendfail; do
    id="orca-env-$setting"
    case_dir="$TMP_ROOT/$id"
    home="$case_dir/home"
    mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
    touch "$home/state/.last-watcher-beat"
    printf 'manual\n' > "$home/config/backlog-backend"
    printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
    if [ "$setting" = malformed ]; then printf 'wrong:selector\n' > "$home/config/launch-env-tmux-session"; fi
    if [ "$setting" = nonregular ]; then rm "$home/config/launch-env-tmux-session"; mkdir "$home/config/launch-env-tmux-session"; fi
    case "$setting" in
      enabled|missing|sendfail) printf 'GH_TOKEN\nGH_CONFIG_DIR\nFM_TEST_NOT_SET\nLANG\n' > "$home/config/launch-env-allowlist" ;;
      empty) : > "$home/config/launch-env-allowlist" ;;
      absent) ;;
      *) printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist" ;;
    esac
    [ "$setting" != missing ] || printf 'FM_TEST_ABSENT\n' >> "$home/config/launch-env-allowlist"
    fm_git_init_commit "$case_dir/project"
    cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Verify the controlled Orca environment source.

## Firstmate spec
Execute read-only environment checks.
EOF
    cat > "$case_dir/probe.sh" <<'EOF'
#!/bin/sh
launch_file=$(cat "$1")
[ ! -e "$launch_file" ] || { echo 'launch file still contains credentials when the worker starts' >&2; exit 1; }
printf '%s\n' "${GH_TOKEN-unset}" "${GH_CONFIG_DIR-unset}" "${DATABASE_URL-unset}" "${FM_TEST_NOT_SET-unset}" "${FM_TEST_PERSONAL-unset}" "${GIT_CONFIG_NOSYSTEM-unset}" "${LANG-unset}"
EOF
    value="synthetic-' \$(touch $case_dir/injected) \`false\`"$'\nline\n\n'
    VALUE="$value" python3 - "$case_dir/source.json" <<'PY'
import json,os,sys
with open(sys.argv[1], 'w') as f:
 json.dump({'GH_TOKEN':os.environ['VALUE'], 'GH_CONFIG_DIR':'scoped-gh', 'DATABASE_URL':'readonly-db', 'FM_TEST_NOT_SET':None, 'LANG':None}, f)
PY
    fb=$(make_orca_fakebin "$case_dir")
    cat > "$fb/tmux" <<'EOF'
#!/usr/bin/env python3
import json,os,sys
if os.environ.get('FM_TEST_SOURCE_UNAVAILABLE') == '1': sys.exit(1)
if sys.argv[1:5] != ['-u','show-environment','-t','=scoped-source']: sys.exit(2)
with open(os.environ['FM_TEST_ORCA_DIR']+'/source.json') as f: data=json.load(f)
names=[sys.argv[5]] if len(sys.argv)>5 else data
for name in names:
 if name not in data: sys.exit(1)
 value=data[name]
 print('-'+name if value is None else name+'='+value)
EOF
    chmod +x "$fb/tmux"
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" \
      FM_TEST_ORCA_LOG="$case_dir/terminal.log" \
      FM_TEST_SOURCE_UNAVAILABLE="$([ "$setting" = unavailable ] && echo 1 || echo 0)" \
      FM_TEST_ORCA_SEND_FAIL="$([ "$setting" = sendfail ] && echo 1 || echo 0)" \
      FM_TEST_ORCA_CONSUME=1 \
      PATH="$fb:$PATH" "$SPAWN" "$id" "$case_dir/project" \
      --mode direct-PR --yolo off --backend orca --harness "/bin/sh '$case_dir/probe.sh' '$case_dir/stage-path'" 2>&1)
    status=$?
    if [ "$setting" = absent ] || [ "$setting" = unavailable ] || [ "$setting" = malformed ] || [ "$setting" = nonregular ] || [ "$setting" = missing ]; then
      expect_code 1 "$status" "unavailable source must refuse: $out"
      [ ! -d "$case_dir/orca-worktrees" ] || fail "source refusal allocated a worktree"
      [ ! -f "$home/state/$id.meta" ] || fail "source refusal published metadata"
      assert_not_contains "$out" synthetic "source refusal leaked a source value"
      pass "Orca refuses source=$setting before allocating resources"
      continue
    fi
    if [ "$setting" = sendfail ]; then
      expect_code 1 "$status" "undelivered controlled-source launch must fail: $out"
      for staged in /tmp/fm-"$id"+*/launch.*.sh; do
        [ ! -e "$staged" ] || fail "undelivered launch left credentials in $staged"
      done
      pass "Orca removes the credential launch file when the launch cannot be delivered"
      continue
    fi
    expect_code 0 "$status" "controlled-source spawn should succeed: $out"
    assert_not_contains "$out" "warning: backend=orca" "a configured source must not warn about ambient Orca values"
    staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$case_dir/terminal.log" | tail -1)
    [ -f "$staged.copy" ] || fail "Orca did not receive the staged launch path"
    [ ! -e "$staged" ] || fail "spawn returned before the pane consumed the launch file"
    [ "$(cat "$staged.mode")" = 600 ] || fail "credential launch file is not private"
    [ "$(stat -c '%a' "$(dirname "$staged")" 2>/dev/null || stat -f '%Lp' "$(dirname "$staged")")" = 700 ] || fail "credential launch directory is not private"
    assert_not_contains "$(cat "$case_dir/terminal.log")" synthetic "source values leaked into terminal input"
    staged_content=$(cat "$staged.copy")
    printf '%s\n' "$staged" > "$case_dir/stage-path"
    failbin=$(fm_fakebin "$case_dir/delete-refusal")
    printf '#!/bin/sh\nexit 1\n' > "$failbin/rm"
    chmod +x "$failbin/rm"
    case "$setting" in
      enabled) expected="$value"$'\nscoped-gh\nunset\nunset\nunset\n1\nunset' ;;
      empty) expected=$'unset\nunset\nunset\nunset\nunset\n1\npersonal-lang' ;;
    esac
    for pane_shell in /bin/sh /bin/bash /bin/zsh; do
      [ -x "$pane_shell" ] || continue
      (umask 077; printf '%s\n' "$staged_content" > "$staged")
      # shellcheck disable=SC2016 # The child pane expands the source path and its failure status.
      result=$(env -i HOME="$case_dir/user-home" PATH="$failbin:$PATH" TERM=xterm \
        "$pane_shell" -i -c '. "$1"; fm_status=$?; [ "$fm_status" -ne 0 ] || exit 2; printf "\nSHELL-STILL-ALIVE\n"' _ "$staged" 2>&1)
      expect_code 0 "$?" "failed deletion must preserve the interactive $pane_shell pane"
      assert_contains "$result" 'cannot remove private launch file' "deletion failure must refuse before worker execution"
      assert_contains "$result" SHELL-STILL-ALIVE "deletion refusal killed the interactive $pane_shell pane"
      [ -f "$staged" ] || fail "failed deletion unexpectedly removed the private launch file"
      mv "$staged" "$staged.reclaimed"
      # shellcheck disable=SC2016 # The child pane expands the source path and its failure status.
      result=$(env -i HOME="$case_dir/user-home" PATH="$PATH" TERM=xterm \
        "$pane_shell" -i -c '. "$1"; fm_status=$?; [ "$fm_status" -ne 0 ] || exit 2; printf "\nSHELL-STILL-ALIVE\n"' _ "$staged.reclaimed" 2>&1)
      expect_code 0 "$?" "a launch file reclaimed before the pane unlinked it must refuse the worker in $pane_shell"
      assert_contains "$result" 'cannot remove private launch file' "a reclaimed launch file must refuse before worker execution"
      assert_contains "$result" SHELL-STILL-ALIVE "a reclaimed launch file killed the interactive $pane_shell pane"
      mv "$staged.reclaimed" "$staged"
      # The line Orca actually received must keep an errexit pane open both when
      # its unlink fails and when the file was reclaimed before the pane opened it.
      delivered=$(grep "/launch\." "$case_dir/terminal.log" | tail -1)
      result=$(env -i HOME="$case_dir/user-home" PATH="$failbin:$PATH" TERM=xterm \
        "$pane_shell" -i -c "set -e; $delivered; printf '\nSHELL-STILL-ALIVE\n'" 2>&1)
      expect_code 0 "$?" "failed deletion must preserve an errexit $pane_shell pane"
      assert_contains "$result" 'cannot remove private launch file' "deletion failure under errexit must refuse before worker execution"
      assert_contains "$result" SHELL-STILL-ALIVE "deletion refusal killed the errexit $pane_shell pane"
      assert_not_contains "$result" 'launch file still contains credentials' "deletion refusal under errexit ran the worker in $pane_shell"
      mv "$staged" "$staged.reclaimed"
      result=$(env -i HOME="$case_dir/user-home" PATH="$PATH" TERM=xterm \
        "$pane_shell" -i -c "set -e; $delivered; printf '\nSHELL-STILL-ALIVE\n'" 2>&1)
      expect_code 0 "$?" "a launch file reclaimed before the pane opened it must preserve an errexit $pane_shell pane"
      assert_contains "$result" SHELL-STILL-ALIVE "a launch file reclaimed before sourcing killed the errexit $pane_shell pane"
      mv "$staged.reclaimed" "$staged"
      result=$(env -i HOME="$case_dir/user-home" PATH="$PATH" TERM=xterm \
        GH_TOKEN=personal-token GH_CONFIG_DIR=personal-gh FM_TEST_PERSONAL=personal-value \
        FM_TEST_NOT_SET=personal-value GIT_CONFIG_NOSYSTEM=0 LANG=personal-lang \
        "$pane_shell" -c ". '$staged'") || fail "controlled-source launch failed in $pane_shell"
      [ "$result" = "$expected" ] || fail "Orca source/allowlist=$setting lost isolation or values in $pane_shell"$'\n'"actual: $result"
      [ ! -e "$case_dir/injected" ] || fail "source value executed shell syntax"
      [ ! -e "$staged" ] || fail "secret-bearing launch file survived sourcing in $pane_shell"
    done
    pass "Orca source/allowlist=$setting preserves controlled values, clears ambient credentials and keeps values off terminal input"
  done
}

# A spawn that fails after Orca accepted the launch leaves the terminal open,
# and that pane may still be about to source the launch file, so abort cleanup
# must not delete it out from under the pending source. The fake Orca accepts
# input without executing it, and a failed backlog transition aborts the spawn
# after delivery.
test_orca_spawn_waits_for_a_slow_pane_before_a_later_failure() {
  local case_dir home id=orca-env-unsourced fb out status staged real_axi
  real_axi=$(command -v tasks-axi) || { pass "skipped live-terminal launch file case (tasks-axi is not installed)"; return 0; }
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
  printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
  "$real_axi" add "$id" "item for $id" --kind ship --file "$home/data/backlog.md" >/dev/null
  fm_git_init_commit "$case_dir/project"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a failed Orca spawn after launch delivery.

## Firstmate spec
Confirm a slow pane still receives the staged launch file before the spawn fails later.
EOF
  fb=$(make_orca_fakebin "$case_dir")
  printf '#!/bin/sh\necho "GH_TOKEN=synthetic-token"\n' > "$fb/tmux"
  cat > "$fb/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then
  echo 'error: "backlog is unwritable"' >&2
  exit 1
fi
exec "$real_axi" "\$@"
SH
  chmod +x "$fb/tmux" "$fb/tasks-axi"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" \
    FM_TEST_ORCA_LOG="$case_dir/terminal.log" FM_TEST_ORCA_CONSUME=1 FM_TEST_ORCA_CONSUME_DELAY=3 \
    PATH="$fb:$PATH" "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a spawn whose backlog transition failed reported success: $out"
  assert_contains "$out" "could not be moved to In flight" "the spawn did not fail at the backlog transition"
  staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$case_dir/terminal.log" | tail -1)
  [ -n "$staged" ] || fail "Orca did not receive the staged launch path: $out"
  [ -f "$staged.copy" ] || fail "spawn removed the launch file before a slow pane ran it: $staged"
  [ ! -e "$staged" ] || fail "the consumed launch file is still present: $staged"
  pass "an Orca spawn waits for a slow pane to consume its launch file before a later failure"
}

# A pane that accepts the source command but never runs it cannot unlink the
# credential-bearing file itself, so the spawn reclaims it and fails visibly.
test_orca_unrun_launch_file_is_reclaimed() {
  local case_dir home id=orca-env-unrun fb out status staged
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
  printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
  fm_git_init_commit "$case_dir/project"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca pane that never runs the launch command.

## Firstmate spec
Confirm the staged credential file is reclaimed.
EOF
  fb=$(make_orca_fakebin "$case_dir")
  printf '#!/bin/sh\necho "GH_TOKEN=synthetic-token"\n' > "$fb/tmux"
  chmod +x "$fb/tmux"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" FM_ORCA_LAUNCH_CONSUME_POLLS=2 \
    FM_TEST_ORCA_LOG="$case_dir/terminal.log" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?
  expect_code 1 "$status" "a spawn whose pane never ran the launch command must fail: $out"
  assert_contains "$out" "did not run the launch command" "the failure must name the unrun launch command"
  staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$case_dir/terminal.log" | tail -1)
  [ -n "$staged" ] || fail "Orca did not receive the staged launch path: $out"
  [ ! -e "$staged" ] || fail "an unrun launch left credentials in $staged"
  assert_contains "$(cat "$home/state/$id.status")" "did not run the launch command" "the failure must reach the task status"
  [ ! -e "$case_dir/terminal-closed" ] || fail "an unrun launch closed the Orca terminal"
  pass "an Orca spawn reclaims a launch file its pane never ran and fails visibly"
}

# A pane that unlinks the launch file after the spawn's last existence check but
# before its reclaim wins the race and launches the worker, so the spawn must
# treat the launch as consumed. The fake rm stands in for that pane.
test_orca_pane_wins_launch_file_race_at_deadline() {
  local case_dir home id=orca-env-race fb out status staged real_rm
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
  printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
  fm_git_init_commit "$case_dir/project"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca pane that unlinks the launch file at the reclaim deadline.

## Firstmate spec
Confirm the spawn treats the launch as consumed.
EOF
  fb=$(make_orca_fakebin "$case_dir")
  real_rm=$(command -v rm)
  printf '#!/bin/sh\necho "GH_TOKEN=synthetic-token"\n' > "$fb/tmux"
  cat > "$fb/rm" <<SH
#!/bin/sh
if [ "\$#" -eq 2 ] && [ "\$1" = -- ]; then
  case "\$2" in
    /tmp/fm-$id+*/launch.*.sh) "$real_rm" -f -- "\$2"; exit 1 ;;
  esac
fi
exec "$real_rm" "\$@"
SH
  chmod +x "$fb/tmux" "$fb/rm"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" FM_ORCA_LAUNCH_CONSUME_POLLS=2 \
    FM_TEST_ORCA_LOG="$case_dir/terminal.log" PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?
  expect_code 0 "$status" "a spawn whose pane won the launch-file race must succeed: $out"
  assert_contains "$out" "spawned $id" "the spawn must report success when the pane consumed the launch file"
  staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$case_dir/terminal.log" | tail -1)
  [ -n "$staged" ] || fail "Orca did not receive the staged launch path: $out"
  [ ! -e "$staged" ] || fail "the launch file survived the race: $staged"
  assert_not_contains "$(cat "$home/state/$id.status" 2>/dev/null)" "refused the worker launch" "the spawn refused a launch the pane consumed"
  pass "an Orca spawn treats a launch file the pane unlinked at the deadline as consumed"
}

# A pane that sources the launch file but cannot unlink it refuses the worker
# and stays interactive; the spawn reclaims the file, fails, and must leave the
# Orca terminal open.
test_orca_launch_file_delete_failure_keeps_terminal() {
  local case_dir home id=orca-env-rmfail fb out status staged
  case_dir="$TMP_ROOT/$id"
  home="$case_dir/home"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
  printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
  fm_git_init_commit "$case_dir/project"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca pane that cannot remove the launch file.

## Firstmate spec
Confirm the worker is refused and the terminal stays open.
EOF
  fb=$(make_orca_fakebin "$case_dir")
  printf '#!/bin/sh\necho "GH_TOKEN=synthetic-token"\n' > "$fb/tmux"
  chmod +x "$fb/tmux"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" FM_ORCA_LAUNCH_CONSUME_POLLS=10 \
    FM_TEST_ORCA_LOG="$case_dir/terminal.log" FM_TEST_ORCA_RM_FAIL=1 PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
  status=$?
  expect_code 1 "$status" "a spawn whose pane could not remove the launch file must fail: $out"
  assert_contains "$(cat "$case_dir/pane.out")" 'cannot remove private launch file' "the pane must refuse the worker launch"
  assert_contains "$(cat "$case_dir/pane.out")" SHELL-STILL-ALIVE "the deletion refusal must keep the pane shell running"
  assert_contains "$(cat "$home/state/$id.status")" "could not remove the launch file" "the failure must reach the task status"
  staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$case_dir/terminal.log" | tail -1)
  [ -n "$staged" ] || fail "Orca did not receive the staged launch path: $out"
  [ ! -e "$staged" ] || fail "the spawn did not reclaim the launch file: $staged"
  [ ! -e "$case_dir/terminal-closed" ] || fail "a launch-file deletion failure closed the Orca terminal"
  pass "an Orca pane that cannot remove its launch file refuses the worker and keeps its terminal"
}

# A spawn interrupted after delivering the launch command is the last owner of
# the credential-bearing file, so it must reclaim it with the same arbitration
# as the consume deadline and leave the terminal open. Each case interrupts the
# real spawn either while it waits for the pane to consume the file or while the
# source text has been delivered but Enter has not. The copy taken before the
# signal stands in for a pane that opened the file just before the reclaim.
test_orca_interrupted_spawn_reclaims_launch_file() {
  local phase sig id case_dir home fb pid status staged i want delivered result
  for phase in consume enter; do
    for sig in TERM HUP INT; do
      id="orca-env-interrupt-$phase-$sig"
      case_dir="$TMP_ROOT/$id"
      home="$case_dir/home"
      mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
      touch "$home/state/.last-watcher-beat"
      printf 'manual\n' > "$home/config/backlog-backend"
      printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
      printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
      fm_git_init_commit "$case_dir/project"
      cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an interrupted Orca spawn after launch delivery.

## Firstmate spec
Confirm the staged credential file is reclaimed.
EOF
      fb=$(make_orca_fakebin "$case_dir")
      printf '#!/bin/sh\necho "GH_TOKEN=synthetic-interrupt-token"\n' > "$fb/tmux"
      chmod +x "$fb/tmux"
      # A background job ignores SIGINT on entry; restore the default so the
      # spawn receives INT as an interactive caller would deliver it.
      FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
        FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
        FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
        FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" \
        FM_TEST_ORCA_LOG="$case_dir/terminal.log" \
        FM_TEST_ORCA_HOLD_TEXT="$([ "$phase" = enter ] && echo 1 || echo 0)" \
        PATH="$fb:$PATH" python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
        "$SPAWN" "$id" "$case_dir/project" --mode direct-PR --yolo off --backend orca \
        --harness "touch '$case_dir/worker-ran'" > "$case_dir/spawn.log" 2>&1 &
      pid=$!
      for ((i = 0; i < 300; i++)); do
        if [ "$phase" = enter ]; then
          [ ! -e "$case_dir/text-delivered" ] || break
        elif [ -f "$case_dir/terminal.log" ] &&
          [ "$(grep -A1 "/launch\." "$case_dir/terminal.log" | sed -n 2p)" = '' ] &&
          [ "$(grep -A1 "/launch\." "$case_dir/terminal.log" | wc -l | tr -d ' ')" = 2 ]; then
          break
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      staged=
      [ ! -f "$case_dir/terminal.log" ] || staged=$(sed -n "s/^[^']*'\([^']*\/launch\.[^'\/]*\.sh\)'.*$/\1/p" "$case_dir/terminal.log" | tail -1)
      if [ -z "$staged" ] || [ ! -f "$staged" ] || ! kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        touch "$case_dir/release"
        wait "$pid"
        fail "$phase/$sig: the spawn was not waiting on a delivered launch file: $(cat "$case_dir/spawn.log")"
      fi
      cp "$staged" "$case_dir/opened-launch.sh"
      kill -"$sig" "$pid"
      touch "$case_dir/release"
      wait "$pid"
      status=$?
      case "$sig" in TERM) want=143 ;; HUP) want=129 ;; INT) want=130 ;; esac
      expect_code "$want" "$status" "$phase/$sig: interrupted spawn must exit with the signal status: $(cat "$case_dir/spawn.log")"
      [ ! -e "$staged" ] || fail "$phase/$sig: interrupted spawn left credentials in $staged"
      [ ! -e "$case_dir/terminal-closed" ] || fail "$phase/$sig: interrupted spawn closed the Orca terminal"
      assert_contains "$(cat "$home/state/$id.status" 2>/dev/null)" "refused the worker launch" "$phase/$sig: the reclaim must reach the task status"
      if [ "$phase" = enter ]; then
        [ "$(grep -A1 "/launch\." "$case_dir/terminal.log" | wc -l | tr -d ' ')" = 1 ] || fail "$phase/$sig: spawn sent Enter after the interrupt"
      fi
      delivered=$(grep "/launch\." "$case_dir/terminal.log" | tail -1)
      result=$(env -i HOME="$case_dir/user-home" PATH="$PATH" TERM=xterm \
        /bin/sh -c "set -e; $delivered; echo SHELL-STILL-ALIVE" 2>&1)
      assert_contains "$result" SHELL-STILL-ALIVE "$phase/$sig: the delivered line killed the pane after the reclaim"
      # shellcheck disable=SC2016 # The pane shell expands its own argument.
      result=$(env -i HOME="$case_dir/user-home" PATH="$PATH" TERM=xterm \
        /bin/sh -c '. "$1" || true; echo SHELL-STILL-ALIVE' _ "$case_dir/opened-launch.sh" 2>&1)
      assert_contains "$result" 'cannot remove private launch file' "$phase/$sig: a pane that opened the file before the reclaim must refuse"
      assert_contains "$result" SHELL-STILL-ALIVE "$phase/$sig: the refusal killed the pane"
      [ ! -e "$case_dir/worker-ran" ] || fail "$phase/$sig: the worker ran after the spawn reclaimed its launch file"
      pass "an Orca spawn interrupted by $sig during the $phase step reclaims its launch file and refuses the worker"
    done
  done
}

# The spawn owns the credential-bearing file from the moment it publishes it, so
# an interrupt before the launch command is sent must still remove it. A fake
# sleep holds the spawn in the pause right after publishing.
test_orca_interrupted_spawn_before_send_removes_launch_file() {
  local sig id case_dir home fb pid status staged i want
  for sig in TERM HUP INT; do
    id="orca-env-interrupt-publish-$sig"
    case_dir="$TMP_ROOT/$id"
    home="$case_dir/home"
    mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
    touch "$home/state/.last-watcher-beat"
    printf 'manual\n' > "$home/config/backlog-backend"
    printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
    printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
    fm_git_init_commit "$case_dir/project"
    cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca spawn interrupted before launch delivery.

## Firstmate spec
Confirm the staged credential file is removed.
EOF
    fb=$(make_orca_fakebin "$case_dir")
    printf '#!/bin/sh\necho "GH_TOKEN=synthetic-interrupt-token"\n' > "$fb/tmux"
    cat > "$fb/sleep" <<SH
#!/bin/sh
if [ "\$1" = 0.3 ] && [ ! -e '$case_dir/published' ]; then
  for f in /tmp/fm-$id+*/launch.*.sh; do
    [ -f "\$f" ] || continue
    printf '%s\n' "\$f" > '$case_dir/published'
    i=0
    while [ ! -e '$case_dir/release' ] && [ "\$i" -lt 100 ]; do /bin/sleep 0.1; i=\$((i + 1)); done
  done
fi
exec /bin/sleep "\$@"
SH
    chmod +x "$fb/tmux" "$fb/sleep"
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" \
      FM_TEST_ORCA_LOG="$case_dir/terminal.log" \
      PATH="$fb:$PATH" python3 -c 'import os,signal,sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
      "$SPAWN" "$id" "$case_dir/project" --mode direct-PR --yolo off --backend orca \
      --harness "touch '$case_dir/worker-ran'" > "$case_dir/spawn.log" 2>&1 &
    pid=$!
    for ((i = 0; i < 300; i++)); do
      [ ! -s "$case_dir/published" ] || break
      kill -0 "$pid" 2>/dev/null || break
      /bin/sleep 0.1
    done
    staged=$(cat "$case_dir/published" 2>/dev/null)
    if [ -z "$staged" ] || [ ! -f "$staged" ] || ! kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      touch "$case_dir/release"
      wait "$pid"
      fail "$sig: the spawn was not paused after publishing its launch file: $(cat "$case_dir/spawn.log")"
    fi
    kill -"$sig" "$pid"
    touch "$case_dir/release"
    wait "$pid"
    status=$?
    case "$sig" in TERM) want=143 ;; HUP) want=129 ;; INT) want=130 ;; esac
    expect_code "$want" "$status" "publish/$sig: interrupted spawn must exit with the signal status: $(cat "$case_dir/spawn.log")"
    [ ! -e "$staged" ] || fail "publish/$sig: interrupted spawn left credentials in $staged"
    ! grep -q "/launch\." "$case_dir/terminal.log" 2>/dev/null || fail "publish/$sig: spawn sent the launch command after the interrupt"
    [ ! -e "$case_dir/worker-ran" ] || fail "publish/$sig: the worker ran after the interrupt"
    pass "an Orca spawn interrupted by $sig before sending the launch command removes its launch file"
  done
}

# tmux versions differ on whether they keep invalid UTF-8, so pin the adapter
# itself: whatever bytes tmux reports must reach the shell assignment unchanged.
test_orca_snapshot_keeps_raw_bytes_tmux_reports() {
  local case_dir fb assignments
  case_dir="$TMP_ROOT/raw-bytes"
  mkdir -p "$case_dir"
  fb=$(fm_fakebin "$case_dir")
  cat > "$fb/tmux" <<'EOF'
#!/bin/sh
[ "$#" -ge 5 ] || exit 0
printf 'GH_TOKEN=raw-\377\376-'"'"'q\n'
EOF
  chmod +x "$fb/tmux"
  printf 'raw-\377\376-'"'"'q' > "$case_dir/expected"
  # shellcheck disable=SC2016 # The child shell expands its own arguments.
  assignments=$(PATH="$fb:$PATH" bash -c '. "$1"; fm_backend_orca_launch_env_args scoped GH_TOKEN' _ "$ROOT/bin/backends/orca.sh") \
    || fail "snapshot refused a value with bytes that are not valid UTF-8"
  # shellcheck disable=SC2016 # The child shell expands the exported value.
  sh -c "export $assignments; printf %s \"\$GH_TOKEN\"" > "$case_dir/observed"
  cmp -s "$case_dir/expected" "$case_dir/observed" || fail "snapshot altered bytes tmux reported"
  pass "the Orca snapshot passes through bytes tmux reports even when they are not valid UTF-8"
}

# Without a configured source, a nonempty allowlist on Orca still resolves from
# the Orca terminal; the spawn proceeds unchanged but says so on stderr.
test_orca_allowlist_without_source_warns() {
  local allowlist case_dir home id fb out status
  for allowlist in named empty; do
    id="orca-warn-$allowlist"
    case_dir="$TMP_ROOT/$id"
    home="$case_dir/home"
    mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
    touch "$home/state/.last-watcher-beat"
    printf 'codex\n' > "$home/config/crew-harness"
    printf 'manual\n' > "$home/config/backlog-backend"
    if [ "$allowlist" = named ]; then
      printf 'GH_TOKEN\n' > "$home/config/launch-env-allowlist"
    else
      : > "$home/config/launch-env-allowlist"
    fi
    fm_git_init_commit "$case_dir/project"
    cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an Orca allowlist without a configured source.

## Firstmate spec
Confirm the spawn reports where allowlisted values come from.
EOF
    fb=$(make_orca_fakebin "$case_dir")
    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$case_dir" PATH="$fb:$PATH" \
      "$SPAWN" "$id" "$case_dir/project" --mode no-mistakes --yolo off --backend orca 2>&1)
    status=$?
    expect_code 0 "$status" "an Orca allowlist without a source should still spawn"$'\n'"$out"
    if [ "$allowlist" = named ]; then
      assert_contains "$out" "warning: backend=orca resolves config/launch-env-allowlist names from the Orca terminal" \
        "a named allowlist without a source must not fall back silently"
    else
      assert_not_contains "$out" "warning: backend=orca" "an empty allowlist forwards no credentials and must not warn"
    fi
  done
  pass "Orca warns when allowlisted names would resolve from the Orca terminal, and stays quiet for an empty allowlist"
}

# The real tmux client sanitizes control characters without UTF-8 mode. A
# private socket and synthetic environment catch corruption the stub cannot.
test_orca_source_preserves_values_without_utf8_locale() {
  local real_tmux case_dir
  real_tmux=$(command -v tmux) || fail "tmux is required for the Orca source locale regression"
  case_dir=$(TMPDIR=/tmp fm_test_tmproot oenv)
  if ! python3 - "$real_tmux" "$case_dir" "$ROOT/bin/backends/orca.sh" <<'PY'
import os, pathlib, shlex, shutil, subprocess, sys
tmux, directory, adapter = sys.argv[1:]
root = pathlib.Path(directory)
socket = str(root / 'tmux.sock')
env = {'PATH': os.environ['PATH'], 'HOME': directory, 'TERM': 'xterm'}
value = "synthetic-' $(false) `false`\nFM_TEST_PHANTOM=evil-é\n\n"
snapshot = '. "$1"; fm_backend_orca_launch_env_args scoped-source "$2"'
def call(args, environment=env):
    return subprocess.run(args, env=environment, capture_output=True, text=True,
                          check=True, timeout=10).stdout
try:
    call([tmux, '-S', socket, '-f', '/dev/null', 'new-session', '-d',
          '-s', 'scoped-source', 'sleep 60'], dict(env, SSH_AUTH_SOCK='/tmp/fm-test-personal-agent'))
    call([tmux, '-S', socket, 'set-environment', '-t', '=scoped-source', 'GH_TOKEN', value])
    call([tmux, '-S', socket, 'set-environment', '-r', '-t', '=scoped-source', 'FM_TEST_NOT_SET'])
    raw = b"synthetic-\xff\xfe-'not-utf8"
    subprocess.run([tmux, '-S', socket, 'set-environment', '-t', '=scoped-source', 'FM_TEST_RAW', raw],
                   env=env, check=True, timeout=10)
    call([tmux, '-S', socket, 'set-environment', '-g', 'FM_TEST_ABSENT', 'personal-global'])
    if call([tmux, '-u', '-S', socket, 'show-environment', '-t', '=scoped-source', 'SSH_AUTH_SOCK']) != 'SSH_AUTH_SOCK=/tmp/fm-test-personal-agent\n':
        raise AssertionError('real tmux did not automatically populate the synthetic personal agent')
    fakebin = root / 'bin'
    fakebin.mkdir()
    wrapper = fakebin / 'tmux'
    wrapper.write_text('#!/bin/sh\nexec '+shlex.quote(tmux)+' -S '+shlex.quote(socket)+' "$@"\n')
    wrapper.chmod(0o755)
    for locale in ['absent', 'C']:
        source_env = dict(env, PATH=str(fakebin)+os.pathsep+env['PATH'])
        if locale == 'C':
            source_env.update(LANG='C', LC_ALL='C', LC_CTYPE='C')
        for names in ['GH_TOKEN', 'GH_TOKEN\nFM_TEST_NOT_SET']:
            assignments = call(['bash', '-c', snapshot, '_', adapter, names], source_env)
            for shell in ['sh', 'bash', 'zsh']:
                if shell == 'zsh' and not shutil.which(shell):
                    continue
                observed = call([shell, '-c', 'export '+assignments+'; test "${SSH_AUTH_SOCK-unset}" = unset && test "${FM_TEST_NOT_SET-unset}" = unset && printf %s "$GH_TOKEN"'], env)
                if observed != value:
                    raise AssertionError('tmux source corrupted the synthetic value: locale='+locale+', shell='+shell)
        raw_assignments = subprocess.run(['bash', '-c', snapshot, '_', adapter, 'FM_TEST_RAW'], env=source_env,
                                         capture_output=True, check=True, timeout=10).stdout
        # tmux versions differ on invalid UTF-8, so compare against the exact
        # bytes this tmux reports rather than the bytes that were set.
        record = subprocess.run(['tmux', '-u', 'show-environment', '-t', '=scoped-source', 'FM_TEST_RAW'],
                                env=source_env, capture_output=True, check=True, timeout=10).stdout
        if not record.startswith(b'FM_TEST_RAW=') or not record.endswith(b'\n'):
            raise AssertionError('real tmux did not report the synthetic raw value')
        reported = record[len(b'FM_TEST_RAW='):-1]
        for shell in ['sh', 'bash', 'zsh']:
            if shell == 'zsh' and not shutil.which(shell):
                continue
            observed = subprocess.run([shell, '-c', b'export '+raw_assignments+b'; printf %s "$FM_TEST_RAW"'], env=env,
                                      capture_output=True, check=True, timeout=10).stdout
            if observed != reported:
                raise AssertionError('tmux source altered the bytes tmux reported: locale='+locale+', shell='+shell)
        for names in ['FM_TEST_ABSENT', 'FM_TEST_PHANTOM']:
            result = subprocess.run(['bash', '-c', snapshot, '_', adapter, names],
                                    env=source_env, capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                raise AssertionError('missing session-local name was accepted: '+names)
            if 'evil' in result.stderr or 'personal-global' in result.stderr:
                raise AssertionError('snapshot refusal echoed a source value')
finally:
    subprocess.run([tmux, '-S', socket, 'kill-server'], env=env,
                   capture_output=True, timeout=10, check=False)
PY
  then fail "real-tmux source must preserve exact values and refuse missing names"; fi
  pass "real tmux preserves absent/C locale values and reported raw bytes, rejects missing/phantom names and excludes the automatic SSH agent"
}

test_orca_source_preserves_values_without_utf8_locale
test_orca_launch_uses_controlled_tmux_environment
test_orca_allowlist_without_source_warns
test_orca_spawn_waits_for_a_slow_pane_before_a_later_failure
test_orca_unrun_launch_file_is_reclaimed
test_orca_interrupted_spawn_reclaims_launch_file
test_orca_interrupted_spawn_before_send_removes_launch_file
test_orca_launch_file_delete_failure_keeps_terminal
test_orca_pane_wins_launch_file_race_at_deadline
test_orca_snapshot_keeps_raw_bytes_tmux_reports
test_orca_fresh_spawn_enters_the_worktree_it_created
test_orca_relaunch_rebinds_a_terminal_proven_gone
test_orca_relaunch_refuses_a_live_terminal
test_orca_relaunch_refuses_an_unreachable_runtime
test_orca_relaunch_refuses_an_unreadable_inventory
test_orca_relaunch_refuses_a_missing_worktree
test_orca_relaunch_adopts_the_worktree_a_redeployed_runtime_forgot
test_orca_relaunch_refuses_to_adopt_a_non_worktree_path
test_orca_control_relaunch_reclaims_and_keeps_exit_refusing

echo "# all fm-spawn-orca-worktree tests passed"
