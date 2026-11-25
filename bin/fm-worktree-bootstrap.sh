#!/usr/bin/env bash
# LOCAL ONLY (never upstream): per-project worktree setup hook.
# Usage: fm-worktree-bootstrap.sh create|teardown <project-path> <worktree> <task-id> <kind>
# Runs config/worktree-bootstrap/<project basename> when executable; failures are warnings.
set -u
FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
CONFIG=${FM_CONFIG_OVERRIDE:-${FM_HOME:-$FM_ROOT}/config}
[ "$#" -ge 2 ] || exit 0
hook=$CONFIG/worktree-bootstrap/$(basename "$2")
[ -x "$hook" ] || exit 0
"$hook" "$@" || echo "warning: worktree bootstrap '$1' failed for $2 (ignored)" >&2
exit 0
