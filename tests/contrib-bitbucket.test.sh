#!/usr/bin/env bash
# tests/contrib-bitbucket.test.sh - behavior of the optional contrib/bitbucket
# helpers against a stubbed twg, with no network: the watch install and its
# poll, the conflict check, the park gates and resume, and the bot approver.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTRIB="$ROOT/contrib/bitbucket"
TMP_ROOT=$(fm_test_tmproot contrib-bitbucket-tests)
JQ_BIN=$(command -v jq) || fail "these tests need jq"
HEAD_SHA=abcdefabcdef1234567890abcdefabcdef123456

# new_home <name>: a firstmate home with a task t1 and a fakebin holding the
# twg stub. Echoes the home.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/fakebin" "$home/twg"
  printf 'window=fm-t1\nkind=ship\n' > "$home/state/t1.meta"
  chmod 600 "$home/state/t1.meta"
  cat > "$home/fakebin/twg" <<'SH'
#!/usr/bin/env bash
dir=${FM_TEST_TWG_DIR:?}
printf '%s\n' "$*" >> "$dir/log"
case "${2:-} ${3:-}" in
  "pull-requests get") cat "$dir/pr-$4.json" ;;
  "pull-requests comment") cat "$dir/comments.json" ;;
  "pull-requests query") cat "$dir/query.json" ;;
  "pull-requests approve") printf '%s\n' "$4" >> "$dir/approved" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$home/fakebin/twg"
  ln -sf "$JQ_BIN" "$home/fakebin/jq"
  : > "$home/twg/log"
  printf '[]\n' > "$home/twg/comments.json"
  printf '%s\n' "$home"
}

# write_pr <home> <id> [state] [build-state] [author-account] [title] [created] [approved-by]
write_pr() {
  local home=$1 id=$2 state=${3:-OPEN} build=${4:-SUCCESSFUL} author=${5:-bot-id}
  local title=${6:-Update a dependency} created=${7:-} approver=${8:-nobody}
  [ -n "$created" ] || created=$(date -u +%Y-%m-%dT%H:%M:%S.000000+00:00)
  printf '{"id":%s,"state":"%s","draft":false,"title":"%s","created_on":"%s","updated_on":"%s","author":{"account_id":"%s","nickname":"the-bot"},"links":{"html":{"href":"https://bitbucket.org/ws/repo/pull-requests/%s"}},"source":{"branch":{"name":"deps/update"},"commit":{"hash":"%s"}},"destination":{"branch":{"name":"main"}},"participants":[{"role":"REVIEWER","approved":true,"user":{"account_id":"%s","display_name":"R"}}],"_commits":[{"hash":"%s"}],"_statuses":[{"key":"build","state":"%s","commit":{"hash":"%s"}}]}\n' \
    "$id" "$state" "$title" "$created" "$created" "$author" "$id" "${HEAD_SHA:0:12}" "$approver" "$HEAD_SHA" "$build" "$HEAD_SHA" \
    > "$home/twg/pr-$id.json"
}

write_comments() {  # <home> <json-objects...>
  local home=$1
  shift
  local IFS=,
  printf '[%s]\n' "$*" > "$home/twg/comments.json"
}

comment() {  # <id> <author> <text>
  printf '{"id":%s,"deleted":false,"user":{"display_name":"%s"},"content":{"raw":"%s"},"links":{"html":{"href":"https://bitbucket.org/c/%s"}},"created_on":"2020-01-01T00:00:00+00:00"}' \
    "$1" "$2" "$3" "$1"
}

run_in() {  # <home> <cmd...>
  local home=$1
  shift
  FM_HOME="$home" FM_TEST_TWG_DIR="$home/twg" PATH="$home/fakebin:$PATH" "$@"
}

poll() {  # <home> [extra args...]
  local home=$1
  shift
  run_in "$home" bash "$CONTRIB/bb-watch-poll.sh" t1 5 --workspace ws --repo repo \
    --no-park --no-conflict-check "$@"
}

test_install_requires_home_and_slugs_and_writes_a_registered_wrapper() {
  local home out rc wrapper
  home=$(new_home install)
  out=$(PATH="$home/fakebin:$PATH" env -u FM_HOME bash "$CONTRIB/bb-watch-install.sh" t1 5 --workspace ws --repo repo 2>&1); rc=$?
  expect_code 2 "$rc" "install without FM_HOME"
  assert_contains "$out" "FM_HOME must name the firstmate home" "the missing home was not named"
  out=$(run_in "$home" bash "$CONTRIB/bb-watch-install.sh" t1 5 --repo repo --no-pr-check 2>&1); rc=$?
  expect_code 2 "$rc" "install without a workspace"
  assert_contains "$out" "a workspace is required" "the missing workspace was not named"
  out=$(run_in "$home" bash "$CONTRIB/bb-watch-install.sh" t1 5 --workspace WS --repo repo --no-pr-check 2>&1); rc=$?
  expect_code 2 "$rc" "install with an invalid workspace slug"

  out=$(BB_WORKSPACE=ws BB_REPO=repo run_in "$home" bash "$CONTRIB/bb-watch-install.sh" t1 5 \
    --no-pr-check --ignore-author 'Review Bot' --ignore-prefix '[bot]' 2>&1); rc=$?
  expect_code 0 "$rc" "install with slugs from the environment: $out"
  wrapper="$home/state/t1-bbwatch.check.sh"
  assert_present "$wrapper" "the watch wrapper was not written"
  [ -x "$wrapper" ] || fail "the watch wrapper is not executable"
  assert_present "$home/state/t1-bbwatch.check-trust" "the watch was not registered"
  assert_absent "$home/state/t1.check.sh" "--no-pr-check created a merge poll"
  write_pr "$home" 5
  out=$(FM_TEST_TWG_DIR="$home/twg" PATH="$home/fakebin:$PATH" bash "$wrapper"); rc=$?
  expect_code 0 "$rc" "the installed wrapper runs the poll"
  assert_contains "$out" "bitbucket PR 5 checks passed on $HEAD_SHA" "the installed wrapper did not poll the pull request"
  pass "bb-watch-install requires a home and valid slugs, and writes a registered wrapper that runs the poll"
}

test_poll_reports_comments_once_and_ignores_configured_noise() {
  local home out
  home=$(new_home comments)
  write_pr "$home" 5 OPEN INPROGRESS
  write_comments "$home" "$(comment 1 Alice 'first')"
  out=$(poll "$home" --ignore-author 'Review Bot' --ignore-prefix '[bot]')
  [ -z "$out" ] || fail "the first poll of a pending build reported something: $out"
  write_comments "$home" "$(comment 1 Alice 'first')" "$(comment 2 'Review Bot' 'auto')" \
    "$(comment 3 Bob '[bot] reply')" "$(comment 4 Carol 'please fix')"
  out=$(poll "$home" --ignore-author 'Review Bot' --ignore-prefix '[bot]')
  [ "$out" = "bitbucket PR 5 1 new comment(s): Carol https://bitbucket.org/c/4" ] \
    || fail "new comments were not reported exactly once with noise ignored: '$out'"
  out=$(poll "$home" --ignore-author 'Review Bot' --ignore-prefix '[bot]')
  [ -z "$out" ] || fail "a seen comment was reported again: $out"
  pass "bb-watch-poll seeds comments silently, reports each new one once, and skips ignored authors and prefixes"
}

test_poll_reports_verdict_changes_and_retires_on_close() {
  local home out ci
  home=$(new_home verdicts)
  write_pr "$home" 5 OPEN SUCCESSFUL
  out=$(poll "$home")
  assert_contains "$out" "checks passed on $HEAD_SHA (ready for review)" "a green head was not reported"
  out=$(poll "$home")
  [ -z "$out" ] || fail "an unchanged green head was reported again: $out"
  write_pr "$home" 5 OPEN FAILED
  out=$(poll "$home")
  [ -z "$out" ] || fail "a failed build that reached the worker was also reported: $out"
  grep -rqF "has a failed build on head $HEAD_SHA" "$home/state/t1.inbox" 2>/dev/null \
    || fail "a failed build was not sent to the worker"

  ci="$home/ci-cmd"
  printf '#!/usr/bin/env bash\necho "GREEN %s"\n' "$HEAD_SHA" > "$ci"
  chmod +x "$ci"
  rm -f "$home/state/t1.bbwatch.last"
  out=$(poll "$home" --ci-cmd "$ci")
  assert_contains "$out" "checks passed" "--ci-cmd did not replace the build-status verdict"

  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/t1-bbwatch.check.sh"
  chmod 700 "$home/state/t1-bbwatch.check.sh"
  write_pr "$home" 5 DECLINED SUCCESSFUL
  out=$(poll "$home")
  assert_contains "$out" "bitbucket PR 5 DECLINED" "a declined pull request was not reported"
  assert_absent "$home/state/t1-bbwatch.check.sh" "a declined pull request did not retire its watch"
  assert_absent "$home/state/t1.bbwatch.last" "a retired watch left its record"

  home=$(new_home cleaned)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/t1-bbwatch.check.sh"
  chmod 700 "$home/state/t1-bbwatch.check.sh"
  rm -f "$home/state/t1.meta"
  out=$(poll "$home")
  [ -z "$out" ] || fail "a cleaned-up task's watch reported something: $out"
  assert_absent "$home/state/t1-bbwatch.check.sh" "a cleaned-up task's watch was not retired"
  [ ! -s "$home/twg/log" ] || fail "a cleaned-up task's watch still read the forge"
  pass "bb-watch-poll reports verdict changes once, honors --ci-cmd, and retires on a closed PR or a cleaned-up task"
}

test_conflict_check_reports_only_the_transition() {
  local home origin out seed
  home=$(new_home conflict)
  origin="$TMP_ROOT/conflict-origin.git"
  seed="$TMP_ROOT/conflict-seed"
  git init -q --bare -b main "$origin"
  git init -q -b main "$seed"
  printf 'base\n' > "$seed/f.txt"
  git -C "$seed" add f.txt
  git -C "$seed" -c user.email=t@t -c user.name=t commit -q -m base
  git -C "$seed" checkout -q -b feature
  printf 'feature\n' > "$seed/f.txt"
  git -C "$seed" -c user.email=t@t -c user.name=t commit -q -am feature
  git -C "$seed" checkout -q main
  git -C "$seed" checkout -q -b clean
  printf 'other\n' > "$seed/g.txt"
  git -C "$seed" add g.txt
  git -C "$seed" -c user.email=t@t -c user.name=t commit -q -m clean
  git -C "$seed" checkout -q main
  printf 'main\n' > "$seed/f.txt"
  git -C "$seed" -c user.email=t@t -c user.name=t commit -q -am main
  git -C "$seed" push -q "$origin" main feature clean
  mkdir -p "$home/projects"
  git clone -q "$origin" "$home/projects/proj"

  out=$(FM_HOME="$home" bash "$CONTRIB/bb-conflict-check.sh" t1 proj clean main 5)
  [ -z "$out" ] || fail "a clean branch was reported as conflicting: $out"
  out=$(FM_HOME="$home" bash "$CONTRIB/bb-conflict-check.sh" t1 proj feature main 5)
  assert_contains "$out" "bitbucket PR 5 CONFLICTS with main" "a new conflict was not reported"
  assert_contains "$out" "f.txt" "the conflicting file was not named"
  out=$(FM_HOME="$home" bash "$CONTRIB/bb-conflict-check.sh" t1 proj feature main 5)
  [ -z "$out" ] || fail "a known conflict was reported again: $out"
  [ "$(cat "$home/state/t1.bbwatch.conflict")" = conflict ] || fail "the conflict record was not kept"
  out=$(FM_HOME="$home" bash "$CONTRIB/bb-conflict-check.sh" t1 missing feature main 5)
  [ -z "$out" ] || fail "a missing project clone raised an alarm: $out"
  [ "$(git -C "$home/projects/proj" status --porcelain)" = "" ] || fail "the conflict check touched the project clone"
  pass "bb-conflict-check reports only the change to conflicted, names the files, and never alarms on a missing clone"
}

test_park_gates_and_resume() {
  local home out comments dir
  home=$(new_home park)
  dir=$(fake_root "$home")
  write_pr "$home" 5 OPEN SUCCESSFUL bot-id t 2020-01-01T00:00:00.000000+00:00
  comments="$home/twg/comments.json"
  out=$(FM_HOME="$home" bash "$dir/bb-park.sh" t1 5 u "$home/twg/pr-5.json" "$comments" RUNNING)
  [ -z "$out" ] && [ ! -e "$home/state/t1.bbpark" ] || fail "a pending build parked the worker"
  printf 'conflict\n' > "$home/state/t1.bbwatch.conflict"
  out=$(FM_HOME="$home" bash "$dir/bb-park.sh" t1 5 u "$home/twg/pr-5.json" "$comments" GREEN)
  [ -z "$out" ] && [ ! -e "$home/state/t1.bbpark" ] || fail "a conflicting branch parked the worker"
  rm -f "$home/state/t1.bbwatch.conflict"
  out=$(FM_HOME="$home" bash "$dir/bb-park.sh" t1 5 u "$home/twg/pr-5.json" "$comments" GREEN --park-days 0)
  [ -z "$out" ] && [ ! -e "$home/state/t1.bbpark" ] || fail "--park-days 0 parked the worker"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/not-ready"
  chmod +x "$home/not-ready"
  out=$(FM_HOME="$home" bash "$dir/bb-park.sh" t1 5 u "$home/twg/pr-5.json" "$comments" GREEN --ready-cmd "$home/not-ready")
  [ -z "$out" ] && [ ! -e "$home/state/t1.bbpark" ] || fail "a failing --ready-cmd did not stop the park"

  assert_absent "$home/control.log" "a gated park still stopped the agent"
  printf 'parked=1\nparked_at=1577836800\nhead=%s\n' "$HEAD_SHA" > "$home/state/t1.bbpark"
  out=$(FM_HOME="$home" bash "$CONTRIB/bb-park.sh" t1 5 u "$home/twg/pr-5.json" "$comments" GREEN)
  [ -z "$out" ] || fail "a parked task with no new activity was resumed: $out"
  write_comments "$home" "$(printf '{"id":9,"created_on":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)")"
  out=$(FM_HOME="$home" bash "$CONTRIB/bb-park.sh" t1 5 u "$home/twg/pr-5.json" "$comments" GREEN)
  assert_contains "$out" "worker t1 could not be resumed after parking (new PR activity" \
    "new activity on a parked task did not attempt a resume"
  assert_contains "$out" "bin/fm-control.sh t1 relaunch --note-file $home/data/t1/parked.md" \
    "a failed resume did not name the command to run by hand"
  assert_grep 'resuming parked PR 5' "$home/state/t1.status" "the resume was not recorded in the status log"
  pass "bb-park parks only a green, unconflicted, ready PR and resumes a parked one on new activity"
}

# fake_root <home>: a copy of contrib/bitbucket beside a bin/ whose worker
# lifecycle tools are stubs, so a park and a resume run end to end. Echoes the
# copied contrib directory.
fake_root() {
  local home=$1 root="$1/fakeroot"
  mkdir -p "$root/bin" "$root/contrib"
  cp -R "$CONTRIB" "$root/contrib/bitbucket"
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$root/bin/fm-pr-lib.sh"
  printf '#!/usr/bin/env bash\necho "state: done"\n' > "$root/bin/fm-crew-state.sh"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/control.log"\n' "$home" > "$root/bin/fm-control.sh"
  chmod +x "$root/bin/fm-crew-state.sh" "$root/bin/fm-control.sh"
  printf '%s\n' "$root/contrib/bitbucket"
}

test_park_stops_an_idle_green_worker_and_resumes_it() {
  local home dir out comments
  home=$(new_home park-live)
  dir=$(fake_root "$home")
  write_pr "$home" 5 OPEN SUCCESSFUL bot-id t 2020-01-01T00:00:00.000000+00:00
  comments="$home/twg/comments.json"
  printf 'working [at=1]: opened PR 5\n' > "$home/state/t1.status"
  out=$(FM_HOME="$home" bash "$dir/bb-park.sh" t1 5 u "$home/twg/pr-5.json" "$comments" GREEN)
  assert_contains "$out" "bitbucket PR 5 worker t1 parked" "an idle green worker was not parked"
  assert_grep "t1 exit" "$home/control.log" "parking did not stop the agent"
  assert_grep "parked_at=" "$home/state/t1.bbpark" "the park was not recorded"
  assert_grep "head=$HEAD_SHA" "$home/state/t1.bbpark" "the park did not record the full head"
  assert_grep "Branch: deps/update (head $HEAD_SHA)" "$home/data/t1/parked.md" "the resume notes miss the branch and head"
  assert_grep "paused [at=" "$home/state/t1.status" "parking did not append a paused status"
  out=$(FM_HOME="$home" bash "$dir/bb-park.sh" t1 5 u "$home/twg/pr-5.json" "$comments" GREEN)
  [ -z "$out" ] || fail "an already parked worker was parked again: $out"
  out=$(FM_HOME="$home" bash "$dir/bb-park.sh" t1 5 u "$home/twg/pr-5.json" "$comments" FAILED)
  assert_contains "$out" "worker t1 resumed from parked (a build FAILED)" "a failed build did not resume the parked worker"
  assert_grep "t1 relaunch --note-file $home/data/t1/parked.md" "$home/control.log" "the resume did not relaunch with the notes"
  assert_absent "$home/state/t1.bbpark" "a resumed worker still looks parked"
  pass "bb-park stops an idle green worker with resume notes and relaunches it on a failed build"
}

test_renovate_approve_dry_run_and_apply() {
  local home out rc old
  home=$(new_home renovate)
  old=$(date -u -v-30d +%Y-%m-%dT%H:%M:%S.000000+00:00 2>/dev/null || date -u -d '-30 days' +%Y-%m-%dT%H:%M:%S.000000+00:00)
  printf '{"page":1,"pagelen":100,"size":6,"hasNextPage":false,"values":[{"id":1},{"id":2},{"id":3},{"id":4},{"id":5},{"id":6}]}\n' \
    > "$home/twg/query.json"
  write_pr "$home" 1
  write_pr "$home" 2 OPEN FAILED
  write_pr "$home" 3 OPEN SUCCESSFUL bot-id 'Update fragile-lib'
  write_pr "$home" 4 OPEN SUCCESSFUL someone-else
  write_pr "$home" 5 OPEN SUCCESSFUL bot-id t "$old"
  write_pr "$home" 6 OPEN SUCCESSFUL bot-id t '' me-id

  out=$(run_in "$home" bash "$CONTRIB/renovate-approve.sh" --workspace ws --repo repo --bot-account-id bot-id 2>&1); rc=$?
  expect_code 2 "$rc" "approve without your account id"
  assert_contains "$out" "your account ID is required" "the missing account id was not named"

  out=$(BB_SKIP_WORDS='FRAGILE' run_in "$home" bash "$CONTRIB/renovate-approve.sh" \
    --workspace ws --repo repo --bot-account-id bot-id --my-account-id me-id 2>&1); rc=$?
  expect_code 0 "$rc" "dry run: $out"
  assert_contains "$out" "#1 would approve" "a green bot PR was not eligible"
  assert_contains "$out" "#2 skip: builds at head FAILED" "a failed build was not skipped"
  assert_contains "$out" '#3 skip: contains "FRAGILE"' "a skip word was not honored case-insensitively"
  assert_contains "$out" "#4 skip: not authored by the bot" "another author was not skipped"
  assert_contains "$out" "#5 skip: older than 14 days" "an old PR was not skipped"
  assert_contains "$out" "#6 skip: already approved by you" "your own approval was not skipped"
  assert_absent "$home/twg/approved" "a dry run approved something"

  out=$(run_in "$home" bash "$CONTRIB/renovate-approve.sh" --workspace ws --repo repo \
    --bot-account-id bot-id --my-account-id me-id --skip-word fragile --apply 2>&1); rc=$?
  expect_code 0 "$rc" "apply: $out"
  [ "$(cat "$home/twg/approved")" = 1 ] || fail "--apply approved something other than the one eligible PR: $(cat "$home/twg/approved")"
  assert_grep 'pull-requests query --workspace ws --repo repo --author bot-id --state OPEN --created-since 14d' \
    "$home/twg/log" "the query did not filter by the bot, state, and window"
  pass "renovate-approve lists decisions in a dry run and approves only green, recent, unapproved bot PRs with --apply"
}

test_install_requires_home_and_slugs_and_writes_a_registered_wrapper
test_poll_reports_comments_once_and_ignores_configured_noise
test_poll_reports_verdict_changes_and_retires_on_close
test_conflict_check_reports_only_the_transition
test_park_gates_and_resume
test_park_stops_an_idle_green_worker_and_resumes_it
test_renovate_approve_dry_run_and_apply
