#!/usr/bin/env bash
# bin/backends/orca.sh - the Orca terminal session-provider adapter.
#
# Orca owns both the task worktree and the terminal endpoint. Escape key support
# remains unsupported until Orca exposes a terminal-send primitive for it.
#
# Target string shape: the Orca terminal id accepted by `orca terminal ...`.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"

# FM_ORCA_BIN names the Orca CLI to run when `orca` on PATH is not the right
# one, such as the per-runtime wrapper an Orca-deployed remote host keeps at
# ~/.orca-<hash>/cli/bin/orca, which sets its own ORCA_USER_DATA_PATH. Unset,
# every call runs `orca` from PATH exactly as before.
fm_backend_orca_cli() {
  "${FM_ORCA_BIN:-orca}" "$@"
}

fm_backend_orca_tool_check() {
  command -v "${FM_ORCA_BIN:-orca}" >/dev/null 2>&1 || { echo "error: backend=orca selected but the '${FM_ORCA_BIN:-orca}' CLI is not installed" >&2; return 1; }
}

fm_backend_orca_runtime_check() {
  fm_backend_orca_tool_check || return 1
  local out
  out=$(fm_backend_orca_cli status --json 2>/dev/null) || {
    echo "error: backend=orca selected but 'orca status --json' failed; start Orca and wait for the runtime to be ready" >&2
    return 1
  }
  # shellcheck disable=SC2016  # Single quotes are deliberate: ${...} belongs to the Node snippet.
  printf '%s' "$out" | node -e '
const fs = require("fs");
let data;
try {
  data = JSON.parse(fs.readFileSync(0, "utf8"));
} catch (err) {
  console.error("error: invalid Orca status JSON: " + err.message);
  process.exit(1);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  console.error("error: Orca runtime is not ready" + (msg ? ": " + msg : ""));
  process.exit(1);
}
const r = data.result || {};
const runtime = r.runtime || {};
const reachable = runtime.reachable ?? r.runtimeReachable;
const state = runtime.state || r.runtimeState || "";
if (reachable === true && state === "ready") process.exit(0);
console.error(`error: backend=orca requires a ready Orca runtime (reachable=${String(reachable)}, state=${state || "unknown"})`);
process.exit(1);
'
}

# Snapshot only the explicitly selected tmux session's local environment, never
# its server-global environment or the invoking process. The caller places these
# quoted assignments in its private staged launch file, never terminal input.
# Every allowlisted name must exist in the session; an explicit -NAME record is
# a deliberate unset, and a missing name refuses rather than falling back.
fm_backend_orca_launch_env_args() {  # <tmux-session> <newline-separated names>
  node - "$1" "$2" <<'JS'
const { spawnSync } = require("child_process");
const [session, names] = process.argv.slice(2);
function refuse(name) {
  // Do not echo tmux output or errors: they may contain credential values.
  const required = name === undefined ? "" : ` (required name ${name})`;
  console.error(`error: cannot snapshot configured tmux launch environment${required}; refusing Orca launch`);
  process.exit(1);
}
function read(name) {
  // Without -u, tmux sanitizes values when the client lacks a UTF-8 locale.
  const args = ["-u", "show-environment", "-t", `=${session}`];
  if (name !== undefined) args.push(name);
  // latin1 maps each byte to one code unit, so values that are not valid UTF-8
  // reach the launch file byte for byte instead of as replacement characters.
  const result = spawnSync("tmux", args, {
    encoding: "latin1", timeout: 10000, maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error || result.status !== 0) refuse(name);
  return result.stdout;
}
// Verify the session even for an empty allowlist. Never derive names from raw
// multiline values or tmux's automatically populated update-environment.
read();
const assignments = [];
for (const name of new Set(names.split("\n").filter(Boolean))) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) refuse();
  // Read each name separately so embedded/trailing newlines are preserved and
  // a value resembling another NAME=value line cannot supply another variable.
  const output = read(name);
  if (!output.endsWith("\n")) refuse(name);
  const record = output.slice(0, -1);
  if (record === `-${name}`) continue;
  if (!record.startsWith(`${name}=`)) refuse(name);
  const value = record.slice(name.length + 1);
  if (value.includes("\0")) refuse(name);
  assignments.push(`${name}='${value.replace(/'/g, "'\\''")}'`);
}
process.stdout.write(assignments.join(" "), "latin1");
JS
}

fm_backend_orca_json_get() {  # <field> ; fields: worktree-id worktree-path terminal-handle worktree-terminal-handle repo-id
  # Terminal handles are accepted only from verified terminal result shapes:
  # result.terminal or a root terminal object with .handle. Undocumented
  # result.id and result.worktree.terminal shapes are ignored until a real Orca
  # smoke run proves them.
  local field=$1
  node -e '
const fs = require("fs");
const field = process.argv[1];
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
const wt = r.worktree || r.item || r;
const explicitTerm = r.terminal || null;
const repo = r.repo || r.repository || r;
function scalar(v) {
  return (typeof v === "string" || typeof v === "number") ? String(v) : "";
}
function handle(obj) {
  if (!obj) return "";
  if (typeof obj === "string" || typeof obj === "number") return String(obj);
  return scalar(obj.handle) || "";
}
let v = "";
if (field === "worktree-id") v = wt.id || wt.worktreeId || r.worktreeId || "";
if (field === "worktree-path") v = wt.path || (wt.git && wt.git.path) || r.path || "";
if (field === "terminal-handle") v = handle(explicitTerm || r) || "";
if (field === "worktree-terminal-handle") v = handle(explicitTerm) || "";
if (field === "repo-id") v = repo.id || repo.repoId || r.repoId || "";
if (!v) process.exit(1);
process.stdout.write(String(v));
' "$field"
}

fm_backend_orca_json_ok() {
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8").trim();
if (!input) process.exit(0);
let data;
try {
  data = JSON.parse(input);
} catch (err) {
  console.error("invalid Orca JSON: " + err.message);
  process.exit(2);
}
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
'
}

fm_backend_orca_run_json() {
  local out
  out=$("$@") || return 1
  printf '%s' "$out" | fm_backend_orca_json_ok
}

fm_backend_orca_repo_ensure() {  # <project-path>
  local project=$1 out repo_id
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli repo show --repo "path:$project" --json 2>/dev/null || true)
  if repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id 2>/dev/null); then
    printf '%s' "$repo_id"
    return 0
  fi
  out=$(fm_backend_orca_cli repo add --path "$project" --json) || return 1
  repo_id=$(printf '%s' "$out" | fm_backend_orca_json_get repo-id) || {
    echo "error: orca repo add did not return a repo id for $project" >&2
    return 1
  }
  printf '%s' "$repo_id"
}

fm_backend_orca_worktree_create() {  # <project-path> <name>
  local project=$1 name=$2 repo_id out wt_id wt_path terminal
  repo_id=$(fm_backend_orca_repo_ensure "$project") || return 1
  # LOCAL ONLY (never upstream): FM_ORCA_REFERENCE=<url> attaches a Jira/issue link.
  local ref_args=()
  [ -n "${FM_ORCA_REFERENCE:-}" ] && ref_args=(--reference "$FM_ORCA_REFERENCE")
  out=$(fm_backend_orca_cli worktree create --repo "id:$repo_id" --name "$name" --no-parent --setup skip ${ref_args[@]+"${ref_args[@]}"} --json) || return 1
  wt_id=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-id) || {
    echo "error: orca worktree create did not return a worktree id for $name" >&2
    return 1
  }
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-terminal-handle 2>/dev/null || true)
  wt_path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree create did not return a path for $name" >&2
    [ -z "$terminal" ] || fm_backend_orca_kill "$terminal" >/dev/null 2>&1 || true
    if fm_backend_orca_remove_worktree "$wt_id" >/dev/null; then
      return 1
    fi
    if [ -n "$terminal" ]; then
      printf '%s\t\t%s' "$wt_id" "$terminal"
    else
      printf '%s\t' "$wt_id"
    fi
    return 2
  }
  printf '%s\t%s' "$wt_id" "$wt_path"
  [ -z "$terminal" ] || printf '\t%s' "$terminal"
}

fm_backend_orca_terminal_create() {  # <worktree-id> <title>
  local worktree_id=$1 title=$2 out terminal
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli terminal create --worktree "id:$worktree_id" --title "$title" --json) || return 1
  terminal=$(printf '%s' "$out" | fm_backend_orca_json_get terminal-handle) || {
    echo "error: orca terminal create did not return a terminal handle for $title" >&2
    return 1
  }
  printf '%s' "$terminal"
}

fm_backend_orca_send_text_line() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text "$text" --enter --json
}

fm_backend_orca_send_literal() {  # <terminal-id> <text>
  local terminal=$1 text=$2
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text "$text" --json
}

fm_backend_orca_remove_worktree() {  # <worktree-id>
  local worktree_id=${1:-}
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot remove worktree" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_run_json fm_backend_orca_cli worktree rm --worktree "id:$worktree_id" --force --json
}

fm_backend_orca_worktree_path() {
  local worktree_id=${1:-} out path
  [ -n "$worktree_id" ] || { echo "error: missing Orca worktree id; cannot resolve worktree path" >&2; return 1; }
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli worktree show --worktree "id:$worktree_id" --json) || return 1
  path=$(printf '%s' "$out" | fm_backend_orca_json_get worktree-path) || {
    echo "error: orca worktree show did not return a path for $worktree_id" >&2
    return 1
  }
  printf '%s' "$path"
}

fm_backend_orca_capture() {  # <terminal-id> <lines>
  local terminal=$1 lines=${2:-40} out
  fm_backend_orca_tool_check || return 1
  out=$(fm_backend_orca_cli terminal read --terminal "$terminal" --limit "$lines" --json) || return 1
  fm_backend_orca_json_text "$out"
}

fm_backend_orca_json_text() {  # <json>
  printf '%s' "$1" | node -e '
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(0, "utf8"));
if (data.ok === false) {
  const msg = data.error && (data.error.message || data.error.code);
  if (msg) console.error(msg);
  process.exit(2);
}
const r = data.result || {};
if (r.terminal && Array.isArray(r.terminal.tail)) {
  process.stdout.write(r.terminal.tail.join("\n"));
} else if (Array.isArray(r.tail)) {
  process.stdout.write(r.tail.join("\n"));
} else {
  process.stdout.write(r.text || r.output || r.content || r.preview || "");
}
'
}

# fm_backend_orca_composer_capture: the orca composer screen - one bounded
# tail read of the live terminal. Deliberately NOT the old 200-line
# backward-paged read: the composer is bottom-anchored, and paging back into
# scrollback is what let a stale startup banner (codex's bordered
# "permissions" box) compete with - and once outrank - the live composer.
fm_backend_orca_composer_capture() {  # <terminal-id> [expected-label]
  fm_backend_orca_capture "$1" "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). Orca's `terminal read` returns
# plain text; whether it can emit ANSI is unverified (orca is not installed
# on the verification machine), so styled stays 0 - the conservative
# degradation - until a live capture proves otherwise.
fm_backend_orca_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_orca_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape (bordered boxes AND the borderless bare-glyph
# row this adapter never learned, which left every claude/codex/pi/muse steer
# unconfirmed) lives in bin/fm-composer-lib.sh.
fm_backend_orca_composer_state() {  # <terminal-id> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_orca_composer_capture "$1") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_orca_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

fm_backend_orca_send_key() {  # <terminal-id> <key>
  local terminal=$1 key=$2
  fm_backend_orca_tool_check || return 1
  case "$key" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C)
      fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --interrupt --json
      ;;
    Enter|enter)
      fm_backend_orca_run_json fm_backend_orca_cli terminal send --terminal "$terminal" --text "" --enter --json
      ;;
    *)
      echo "error: unsupported Orca key '$key'" >&2
      return 1
      ;;
  esac
}

# fm_backend_orca_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop (bin/fm-composer-lib.sh:
# fm_composer_submit_retry_core) against the shared composer verdict, so a
# slash-command popup placeholder fill gets the required second Enter without
# duplicating text.
fm_backend_orca_send_text_submit() {  # <terminal-id> <text> <retries> <enter-sleep> <settle>
  local terminal=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_backend_orca_tool_check || { printf 'send-failed'; return 0; }
  fm_backend_orca_send_literal "$terminal" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_orca_send_key fm_backend_orca_composer_state \
    "$terminal" "$retries" "$sleep_s"
}

# fm_backend_orca_worktree_show_fields: one `worktree show` answer on stdin,
# printed as "<ok|notfound|error>\t<id>\t<path>". Only a structured
# selector_not_found is `notfound`; every other failure is `error`.
fm_backend_orca_worktree_show_fields() {
  node -e '
const fs = require("fs");
let d;
try { d = JSON.parse(fs.readFileSync(0, "utf8")); } catch (err) { process.stdout.write("error\t\t"); process.exit(0); }
if (d && d.ok === true && d.result && d.result.worktree) {
  const w = d.result.worktree;
  const id = typeof w.id === "string" ? w.id : "";
  const p = typeof w.path === "string" ? w.path : "";
  process.stdout.write((id && p ? "ok" : "error") + "\t" + id + "\t" + p);
} else if (d && d.ok === false && d.error && d.error.code === "selector_not_found") {
  process.stdout.write("notfound\t\t");
} else {
  process.stdout.write("error\t\t");
}
'
}

# fm_backend_orca_worktree_resolve: the Orca worktree id that names a task's
# recorded worktree on the runtime this process reaches now. Prints that id or
# fails with one reason on stderr; it never creates a worktree or a checkout.
#
# The recorded id is used when the runtime still resolves it to the recorded
# path. A runtime that answers it with a structured not-found has lost its
# registry, which is what an Orca-deployed remote host does when the app
# redeploys its server with a fresh data directory after the host restarts:
# the git worktree is still on disk, but Orca no longer knows it. Only then,
# and only when the recorded path is still a linked git worktree of the
# recorded project, the project is registered again with Orca (the same
# idempotent repository registration a fresh spawn does, no checkout) and the
# existing path is looked up by its path selector. Any other answer fails.
fm_backend_orca_worktree_resolve() {  # <recorded-worktree-id> <worktree-path> <project-path>
  local recorded=${1-} wt=${2-} project=${3-} out fields status id path wt_real path_real
  local wt_common proj_common wt_top proj_top
  if [ -z "$recorded" ] || [ -z "$wt" ] || [ -z "$project" ]; then
    echo "error: the task record lacks an Orca worktree id, worktree path, or project" >&2
    return 1
  fi
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || {
    echo "error: the recorded worktree '$wt' is not on disk" >&2
    return 1
  }
  out=$(fm_backend_orca_cli worktree show --worktree "id:$recorded" --json 2>/dev/null) || true
  fields=$(printf '%s' "$out" | fm_backend_orca_worktree_show_fields)
  IFS=$'\t' read -r status id path <<< "$fields"
  case "$status" in
    ok)
      path_real=$(cd "$path" 2>/dev/null && pwd -P) || path_real=$path
      if [ "$id" = "$recorded" ] && [ "$path_real" = "$wt_real" ]; then
        printf '%s' "$recorded"
        return 0
      fi
      echo "error: Orca resolves worktree id '$recorded' to '$path' (id '$id'), not the recorded worktree '$wt'" >&2
      return 1
      ;;
    notfound) ;;
    *)
      echo "error: Orca could not be asked about worktree id '$recorded'" >&2
      return 1
      ;;
  esac
  # The runtime does not know the recorded id. Adopt the existing worktree
  # only when it is provably a linked worktree of the recorded project.
  wt_common=$(git -C "$wt_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || wt_common=
  proj_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || proj_common=
  wt_top=$(git -C "$wt_real" rev-parse --show-toplevel 2>/dev/null) || wt_top=
  proj_top=$(git -C "$project" rev-parse --show-toplevel 2>/dev/null) || proj_top=
  if [ -z "$wt_common" ] || [ "$wt_common" != "$proj_common" ] || [ -z "$wt_top" ] \
    || [ "$(cd "$wt_top" && pwd -P)" != "$wt_real" ] || [ "$wt_top" = "$proj_top" ]; then
    echo "error: Orca no longer knows worktree id '$recorded', and '$wt' is not a linked git worktree of the recorded project '$project', so it cannot be adopted" >&2
    return 1
  fi
  fm_backend_orca_repo_ensure "$project" >/dev/null || {
    echo "error: Orca no longer knows worktree id '$recorded', and the recorded project '$project' could not be registered with it again" >&2
    return 1
  }
  out=$(fm_backend_orca_cli worktree show --worktree "path:$wt_real" --json 2>/dev/null) || true
  fields=$(printf '%s' "$out" | fm_backend_orca_worktree_show_fields)
  IFS=$'\t' read -r status id path <<< "$fields"
  path_real=$(cd "$path" 2>/dev/null && pwd -P) || path_real=$path
  if [ "$status" != ok ] || [ "$path_real" != "$wt_real" ] || ! fm_backend_orca_worktree_id_valid "$id"; then
    echo "error: Orca no longer knows worktree id '$recorded', and after registering '$project' again it still does not list the existing worktree '$wt'; refusing rather than creating a new one" >&2
    return 1
  fi
  printf '%s' "$id"
}

# fm_backend_orca_endpoint_absence_recheck: the Orca half of the control
# plane's endpoint-absence proof (bin/fm-control-lib.sh's
# fm_control_endpoint_absence_verdict owns how a verdict is used). Orca has no
# recovery-grade agent classifier, so it can never say a terminal holds no
# agent; it can only prove the recorded terminal is no longer there at all.
# Prints exactly one of:
#   gone    - the runtime is ready, the recorded worktree still resolves
#             (fm_backend_orca_worktree_resolve, which may register the
#             project again but never creates a worktree), that worktree's
#             live terminal inventory is complete and omits the recorded
#             handle, and `terminal show` answers the handle with a structured
#             stale or not-found error.
#   present - the recorded handle is still a live terminal.
#   unknown - anything else: CLI missing or failing, runtime not ready, the
#             worktree missing or unadoptable, a truncated or malformed
#             inventory, a host the inventory omitted, answers from different
#             runtimes, or any other answer from `terminal show`.
# A terminal list for an unknown worktree selector answers an empty list with
# ok=true, so resolving the worktree first is what makes an empty list mean
# anything.
fm_backend_orca_endpoint_absence_recheck() {  # <terminal-handle> <orca-worktree-id> <worktree-path> <project-path>
  local terminal=${1-} recorded=${2-} wt=${3-} project=${4-} worktree_id wt_out list_out show_out
  if [ -z "$terminal" ] || [ -z "$recorded" ]; then
    printf 'unknown'
    return 0
  fi
  fm_backend_orca_runtime_check >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  worktree_id=$(fm_backend_orca_worktree_resolve "$recorded" "$wt" "$project" 2>/dev/null) || { printf 'unknown'; return 0; }
  wt_out=$(fm_backend_orca_cli worktree show --worktree "id:$worktree_id" --json 2>/dev/null) || { printf 'unknown'; return 0; }
  list_out=$(fm_backend_orca_cli terminal list --worktree "id:$worktree_id" --json 2>/dev/null) || { printf 'unknown'; return 0; }
  # A not-found answer exits non-zero with its structured error on stdout.
  show_out=$(fm_backend_orca_cli terminal show --terminal "$terminal" --json 2>/dev/null) || true
  FM_ORCA_WT_JSON=$wt_out FM_ORCA_LIST_JSON=$list_out FM_ORCA_SHOW_JSON=$show_out \
    node -e '
const [terminal, worktreeId] = process.argv.slice(1);
function verdict(v) { process.stdout.write(v); process.exit(0); }
function parse(name) {
  try { return JSON.parse(process.env[name] || ""); } catch (err) { verdict("unknown"); }
}
const wt = parse("FM_ORCA_WT_JSON");
const list = parse("FM_ORCA_LIST_JSON");
const show = parse("FM_ORCA_SHOW_JSON");
const runtimes = new Set();
for (const d of [wt, list, show]) {
  if (!d || typeof d !== "object") verdict("unknown");
  const id = d._meta && d._meta.runtimeId;
  if (typeof id === "string" && id) runtimes.add(id);
}
if (runtimes.size > 1) verdict("unknown");
if (wt.ok !== true || !wt.result) verdict("unknown");
const w = wt.result.worktree || {};
if (w.id !== worktreeId) verdict("unknown");
if (list.ok !== true || !list.result || !Array.isArray(list.result.terminals)) verdict("unknown");
if (list.result.truncated === true) verdict("unknown");
const scope = list.result.hostScope;
const host = typeof w.hostId === "string" ? w.hostId : "";
if (host && scope && Array.isArray(scope.omittedHostIds) && scope.omittedHostIds.includes(host)) verdict("unknown");
for (const t of list.result.terminals) {
  if (!t || typeof t.handle !== "string" || !t.handle) verdict("unknown");
  if (t.handle === terminal) verdict("present");
}
if (show.ok === true) {
  const st = show.result && show.result.terminal;
  verdict(st && st.handle === terminal ? "present" : "unknown");
}
const code = show.ok === false && show.error && show.error.code;
if (code === "terminal_handle_stale" || code === "terminal_not_found") verdict("gone");
verdict("unknown");
' "$terminal" "$worktree_id" 2>/dev/null || printf 'unknown'
}

# fm_backend_orca_kill: close one recorded task terminal. A missing CLI is a
# close that was never even attempted, not an endpoint proven gone - with no
# CLI there is no read that could show the terminal absent - so it reports the
# failure its tool check already named instead of a success. The close call
# itself stays best-effort: whether an accepted-then-failed close left the
# terminal alive is not yet decidable without a presence re-read proven
# against the real Orca binary (docs/verification/runtime-backends.md
# "Endpoint close").
fm_backend_orca_kill() {  # <terminal-id>
  fm_backend_orca_tool_check || return 1
  fm_backend_orca_cli terminal close --terminal "$1" --json >/dev/null 2>&1 || true
}
