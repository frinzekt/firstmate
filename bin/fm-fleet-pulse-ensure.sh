#!/usr/bin/env bash
# fm-fleet-pulse-ensure.sh - start the fleet pulse in the background if it is not already running.
#
# usage: fm-fleet-pulse-ensure.sh [SECONDS]   (default 300)
#
# Idempotent: a live pid in state/.fleet-pulse.pid means nothing to do. The loop it starts exits
# by itself once the session that holds state/.lock is gone, so it never outlives firstmate.
# Never fails the caller: every problem is silent and exits 0.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
home=${FM_HOME:-$root}
state=$home/state
interval=${1:-300}
[ -d "$state" ] || exit 0
pidfile=$state/.fleet-pulse.pid
if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi
FM_PULSE_EXIT_WITH_LOCK=1 nohup "$root/bin/fm-fleet-pulse.sh" --loop "$interval" >/dev/null 2>&1 &
echo $! >"$pidfile"
exit 0
