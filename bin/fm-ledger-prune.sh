#!/usr/bin/env bash
# fm-ledger-prune.sh - drop old records from the fleet history ledgers.
#
# usage: fm-ledger-prune.sh [--days N] [--dry-run] [--help]
#   --days N    keep records from the last N days (default 60)
#   --dry-run   print what would be dropped and change nothing
#
# Touches exactly two files and nothing else: state/fleet-ledger.jsonl (record time `ts`,
# epoch seconds) and data/pipeline-spend.jsonl (record time `recorded_at`, UTC ISO).
# Reports, briefs, the backlog, the done archive, and every other file are never read or
# written. A record is dropped only when its time parses and is older than the cutoff; a
# line that is not JSON, or has no readable time, is kept, because pruning must never
# discard what it cannot judge. Kept lines are copied byte for byte.
#
# Each file is rewritten through a temporary file in its own directory and an atomic mv,
# and only when something is dropped. Producers append to these files while firstmate
# runs, so if a file's size changes between the read and the swap the rewrite is
# abandoned and retried (three tries), then that file is left untouched and reported.
# Absent files are skipped. It installs no schedule; the fleet mod README has a one-line
# cron example. Bash 3.2 compatible.
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_PRUNE_NOW (epoch, tests).
# Exit status: 0 done (or nothing to do), 1 a file could not be pruned, 2 bad usage.
set -u

fm_prune_usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# fm_prune_filter <epoch-field|recorded_at> <cutoff>: jq program text selecting lines to KEEP.
fm_prune_keep_expr() {  # <ledger|spend>
  case "$1" in
    ledger) printf '%s' '(.ts | if type == "number" then . else null end)' ;;
    *) printf '%s' '(.recorded_at | if type == "string" then (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) else null end)' ;;
  esac
}

# fm_prune_file <file> <ledger|spend> <cutoff> <dry-run 0|1>: prints one summary line.
fm_prune_file() {
  local file=$1 kind=$2 cutoff=$3 dry=$4 expr tries=0 size1 size2 tmp kept dropped total mode
  [ -f "$file" ] || { printf '%s: absent, skipped\n' "$file"; return 0; }
  expr=$(fm_prune_keep_expr "$kind")
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    size1=$(wc -c <"$file" | tr -d ' ')
    tmp=$(mktemp "$file.prune.XXXXXX") || { echo "fm-ledger-prune: cannot create a temporary file beside $file" >&2; return 1; }
    # jq -R reads each line raw; a line that parses and is older than the cutoff is dropped.
    if ! jq -R -r --argjson cut "$cutoff" '
        . as $line
        | (try fromjson catch null) as $r
        | (if ($r | type) == "object" then ($r | '"$expr"') else null end) as $t
        | if $t != null and $t < $cut then empty else $line end' "$file" >"$tmp" 2>/dev/null; then
      rm -f "$tmp"
      echo "fm-ledger-prune: could not read $file" >&2
      return 1
    fi
    total=$(grep -c '' "$file" 2>/dev/null || true)
    kept=$(grep -c '' "$tmp" 2>/dev/null || true)
    dropped=$((total - kept))
    if [ "$dropped" -le 0 ] || [ "$dry" = 1 ]; then
      rm -f "$tmp"
      if [ "$dry" = 1 ]; then
        printf '%s: would drop %s of %s records, keep %s\n' "$file" "$dropped" "$total" "$kept"
      else
        printf '%s: dropped 0 of %s records, keep %s\n' "$file" "$total" "$kept"
      fi
      return 0
    fi
    size2=$(wc -c <"$file" | tr -d ' ')
    if [ "$size1" = "$size2" ]; then
      mode=$(stat -f %Lp "$file" 2>/dev/null || stat -c %a "$file" 2>/dev/null || echo 644)
      chmod "$mode" "$tmp" 2>/dev/null
      if mv -f "$tmp" "$file"; then
        printf '%s: dropped %s of %s records, kept %s\n' "$file" "$dropped" "$total" "$kept"
        return 0
      fi
    fi
    rm -f "$tmp"
  done
  echo "fm-ledger-prune: $file kept changing while it was rewritten; left untouched" >&2
  return 1
}

fm_prune_main() {
  local days=60 dry=0 root home state data now cutoff rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help) fm_prune_usage; return 0 ;;
      --dry-run) dry=1 ;;
      --days)
        [ "$#" -ge 2 ] || { echo "fm-ledger-prune: --days needs a number" >&2; return 2; }
        days=$2
        shift
        ;;
      *) echo "fm-ledger-prune: unknown argument: $1" >&2; return 2 ;;
    esac
    shift
  done
  case "$days" in '' | *[!0-9]* | 0) echo "fm-ledger-prune: --days must be a positive integer" >&2; return 2 ;; esac
  command -v jq >/dev/null 2>&1 || { echo "fm-ledger-prune: jq not found" >&2; return 1; }
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  home=${FM_HOME:-$root}
  state=${FM_STATE_OVERRIDE:-$home/state}
  data=${FM_DATA_OVERRIDE:-$home/data}
  now=${FM_PRUNE_NOW:-$(date +%s)}
  cutoff=$((now - days * 86400))
  [ "$dry" = 1 ] && echo "fm-ledger-prune: dry run, keeping the last $days days; nothing will be changed"
  fm_prune_file "$state/fleet-ledger.jsonl" ledger "$cutoff" "$dry" || rc=1
  fm_prune_file "$data/pipeline-spend.jsonl" spend "$cutoff" "$dry" || rc=1
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_prune_main "$@"
fi
