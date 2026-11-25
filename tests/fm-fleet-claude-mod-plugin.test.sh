#!/usr/bin/env bash
# The Claude Code fleet pane mod (.claude/mods/firstmate-fleet) under the real installed
# Claude Code: `claude plugin validate --strict` on the physical folder, then its own
# `claude plugin test` suites (tests/*.test.ts inside the mod), which run the hooks module
# in the engine's own host against a mocked clock, environment, file system, and drawing
# surface. No model turn is submitted and no credential is spent, so the guard runs by
# default wherever `claude` is installed. The function-hooks flag is set on this test's own
# processes only and never written into any settings file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_FLEET_PLUGIN_TEST claude

MOD="$ROOT/.claude/mods/firstmate-fleet"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
TMP_ROOT=$(fm_test_tmproot fm-fleet-claude-mod-plugin)

test_validate_strict() {
  local report
  if ! report=$(CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin validate --strict "$MOD" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION refused the fleet mod under strict validation"
  fi
  # The scan is the engine's own reading of the module: what it hooks, calls, and reads.
  local needle
  for needle in \
    "ui.render{component=Pane, requestId=fleet}" \
    "command.run{command=fleet}" \
    "env reads: CLAUDE_CODE_ENABLE_FUNCTION_HOOKS, FM_HOME, FM_ROOT_OVERRIDE, FM_STATE_OVERRIDE" \
    "env writes: nothing"; do
    case "$report" in
      *"$needle"*) : ;;
      *)
        printf '%s\n' "$report" >&2
        fail "Claude Code $CLAUDE_VERSION: the scan of the fleet mod is missing '$needle'"
        ;;
    esac
  done
  case "$report" in
    *"process.run"*|*"http.fetch"*|*"env.set"*|*"prompt."*|*"tool.call"*|*"fs.write"*)
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION scanned a capability the fleet mod must not use"
      ;;
  esac
  pass "Claude Code $CLAUDE_VERSION validates the fleet mod strictly, hooking only its pane and /fleet and reading only the home and state environment"
}

test_plugin_suites() {
  local report
  if ! report=$(cd "$TMP_ROOT" && CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test "$MOD" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION failed the fleet mod's plugin test suites"
  fi
  printf '%s\n' "$report" | grep -Eq '^ *[1-9][0-9]* pass$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION ran no fleet mod plugin test"
  }
  printf '%s\n' "$report" | grep -Eq '^ *0 fail$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION reported fleet mod plugin test failures"
  }
  pass "Claude Code $CLAUDE_VERSION runs the fleet mod's plugin test suites clean: formatting, pulse parsing, inertness without the flag, and the polled pane"
}

fm_test_run test_validate_strict test_plugin_suites
