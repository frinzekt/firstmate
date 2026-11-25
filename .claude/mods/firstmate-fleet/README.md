# Firstmate Fleet

A Claude Code pane that shows every live worker of this Firstmate home as a card, so the captain sees the whole fleet at a glance.
It is a small mod modeled on [claude-flightdeck](https://github.com/scasella/claude-flightdeck) (MIT, Copyright (c) 2026 Stephen Casella), not a fork of it.
Only its number and bar helpers and its pane skeleton are adapted, and the licence text is in `LICENSE-flightdeck`.

## What it shows

One card per worker, read from `state/<id>.meta`, `.busy-state`, `.status`, and the worker's Claude transcript.
Each card has four lines.

- Glyph, task id, kind (ship or scout), state, and the age of the last event.
- A title: the transcript's title, else the branch, else the model.
- The last status line the worker wrote.
- A context gauge and an estimated cost.

The header counts workers by state and totals the estimated cost.
A worker waiting on the captain (needs-decision, blocked, or failed) sorts to the top, draws in the error color, and is counted as "needs you".
A card's state is busy or idle from the hook-fed busy-state record, unless a newer paused, blocked, needs-decision, failed, or done status overrides it.

Sample, rendered from live fleet data at 64 columns:

```text
FLEET · 1 busy · 9 paused
10 workers · est. ~$622

● fleet-dashboard-build ship                             busy 6m
  claude-sonnet-5-5
  setup done; branch created, report+flightdeck read; building…
  ▰▰▰▰▰▰▰▰▰▱ ~91% 184k  ~$3.33

◌ ci-e2e-parallel-setup ship                           paused 2d
  flapuz/NOISSUE
  waiting on captain merge (risk form + approval) of PR
  ▰▰▰▰▰▰▰▰▰▰ ~97% 195k  ~$7.32

◌ ci-spark-driver-heap ship                            paused 2d
  flapuz/NOISSUE
  waiting on captain merge (risk form + approval) of PR
  ▰▰▰▰▰▰▰▱▱▱ ~69% 138k  ~$3.29

◌ rtfv-500-log-cause ship                              paused 2d
```

## History

Below the live cards the pane lists finished tasks, one collapsed line each: task, outcome (merged via pr or local, or cleaned up), how long ago, duration from dispatch to finish, and no-mistakes spend in tokens (in plus out; a `+` marks a lower bound, `-` means none recorded).
The default window is the last 14 days.
`/lookout history` flips to 60 days and back, and `/lookout history 14` or `/lookout history 60` picks one; the pane draws at most 25 rows and counts the rest.
Nothing older than 60 days is shown, and `bin/fm-ledger-prune.sh` deletes it (below).

It reads `state/fleet-ledger.jsonl` (task.dispatched, pr_ready, merged, cleaned_up) joined with `data/pipeline-spend.jsonl`.
Both files are opt-in (`config/fleet-ledger`, `config/pipeline-spend`) and only started recording on 2026-11-02, so the history is empty or partial before then.
The pane says so with an empty-state line: `no finished tasks in the last 14d (ledger records since <date>)`.
Absent or empty files, duplicate records, and malformed lines are tolerated.

## Pruning old records

`bin/fm-ledger-prune.sh [--days 60] [--dry-run]` drops records older than the window from those two files and nothing else.
It never touches reports, briefs, the backlog, the done archive, or any other file.
A line that is not JSON or has no readable time is kept.
Each file is rewritten through a temporary file and an atomic move, only when something is dropped, and is left untouched if a producer appends while it is being rewritten.
It prints how many records it dropped or kept per file, and `--dry-run` prints the counts and changes nothing.
It installs no schedule; to run it daily, a crontab line such as this does it:

```text
17 4 * * * FM_HOME=/path/to/firstmate-home /path/to/firstmate-home/bin/fm-ledger-prune.sh --days 60 >/dev/null
```

## Enable it

The mod does nothing unless `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` is set exactly, the same gate as the Calm mod.
Never set that variable in a worker's launch environment: it would load the mod inside the worker.

1. Run the sidecar so the pulse file exists and stays fresh, from the home's root, in any spare pane:
   `bin/fm-fleet-pulse-ensure.sh` (session start runs it for you; it refreshes every 5 minutes and stops when firstmate exits).
   One run (`--once`) writes `state/.fleet-pulse.json` atomically and exits; `--stdout` prints it instead.
2. Start the primary session with the flag: `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude`.
3. The pane opens at session start; `/lookout` reopens it and `/lookout close` hides it.

How Claude Code finds the mod.
Calm is reached through the tracked symlink `.agents/skills/firstmate-calm`, which points at `.claude/mods/firstmate-calm`; `.claude/skills` is itself a symlink to `.agents/skills`, so both paths resolve to the mod.
`docs/calm.md` describes the per-mod link as living under `.claude/skills`, but the link that actually exists is under `.agents/skills`.
The fleet mod is loaded the same way once `.agents/skills/firstmate-fleet` links to `../../.claude/mods/firstmate-fleet`:

```sh
ln -s ../../.claude/mods/firstmate-fleet .agents/skills/firstmate-fleet
```

Without that link, launch with `claude --plugin-dir .claude/mods/firstmate-fleet`.
The plugin name is `fmfleet`, distinct from Calm's `fm`, and the two claim different surfaces, so they coexist.

## How it works

`bin/fm-fleet-pulse.sh` is the only reader of worker records.
It writes one small JSON file and never writes to a worker, a project, or a pane.
The mod has no process access: it checks that file every two seconds, re-reads it only when its size or time changed, and draws it.
The drawing is display only and never reaches the model.
Workers on other harnesses are listed with state and last status but no context or cost, because they have no Claude transcript.
Remote secondmates are not covered.

## Known limits

- Context and cost are estimates, drawn with a `~`.
  The transcript carries no cost, so cost is tokens times a small price table in the sidecar, counting each message once over the worker's newest transcript.
  The context window is assumed to be 1M for opus and sonnet, or when the model id says so or the last request already exceeded 200k; otherwise (haiku) 200k.
  A worker with several sessions only counts its newest one.
- The function-hooks API is early access and version-scoped.
  It was checked against Claude Code 2.1.316 here and can change without notice, so re-run `tests/fm-fleet-claude-mod-plugin.test.sh` after an upgrade.
- The pane docks only in a wide terminal (about 144 columns, fullscreen); otherwise Claude Code seats an eight-row inline summary of the same cards.
  Docked live rendering was not exercised by the tests, which draw the pane through the engine's test host.
- Nothing in the mod runs the sidecar; a stale pulse is called out in the pane ("pulse is 10m old").
- If the pane cannot render, the one-day fallback is text only: the same pulse file feeding a status line or `$.ui.log` rows.
  Until then `bin/fm-fleet-pulse.sh --stdout | jq` shows the same data.

## Tests

- `tests/fm-fleet-pulse.test.sh` - the sidecar's parsing and math, the history join, and a fixture fleet end to end.
- `tests/fm-ledger-prune.test.sh` - prune windows, dry run versus real, and that no other file is touched.
- `tests/fm-fleet-claude-mod-plugin.test.sh` - `claude plugin validate --strict` plus the mod's own suites in `tests/fleet.test.ts`: formatting, history windows and empty state, pulse parsing, inertness without the flag, and the polled pane.
