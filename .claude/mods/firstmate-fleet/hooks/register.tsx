// Firstmate Fleet for Claude Code: the hooks module of the fleet pane mod, plugin name
// `fmfleet` (distinct from Calm's `fm`).
//
// A Claude Code "mod" is a plugin whose behavior lives in one hooks module. Claude Code
// may load this module through its rollout flag or `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS`,
// but every handler requires that environment variable to equal `1`, so rollout-only
// loading remains a complete no-op. The pane skeleton (open, `ui.render` on Pane, the
// error fallback draw) is modeled on claude-flightdeck, MIT, Copyright (c) 2026 Stephen
// Casella; see ../LICENSE-flightdeck.
//
// The mod has no process access: bin/fm-fleet-pulse.sh writes `state/.fleet-pulse.json`
// and this module only polls that one small file (stat, then read on change) and draws
// it. Nothing here reads a worker pane or sends anything to the model; the pane is a
// display surface. ../lib/fm-fleet-format.ts owns every line the pane draws.
import type { EngineInterface, Register } from "claude-code";
import {
  fleetStateDirectory,
  HISTORY_DEFAULT_DAYS,
  HISTORY_WINDOWS,
  nextHistoryWindow,
  paneRows,
  parsePulse,
  type Pulse,
  type Row,
} from "../lib/fm-fleet-format.ts";

const PANE = "fleet";
const TITLE = "Fleet";
const COMMAND = "lookout";
/** The docked pane's requested width and its inline height; wide terminals dock it. */
const PANE_COLUMNS = 140;
const PANE_ROWS = 8;
/** How often the pulse file is checked for a change. */
const POLL_MS = 2000;
/** A file changed this recently may be replaced again within its timestamp's resolution. */
const SETTLED_MS = 3000;

let activation: Promise<boolean> | undefined;
let pulsePath: string | undefined;
let pulse: Pulse | undefined;
let stamp: string | undefined;
/** The history window the pane shows: 14 days by default, 60 on demand. */
let historyDays = HISTORY_DEFAULT_DAYS;
let timer: { cancel(): void } | undefined;

function isActivated($: EngineInterface): Promise<boolean> {
  if (activation === undefined) {
    activation = $.env.get("CLAUDE_CODE_ENABLE_FUNCTION_HOOKS").then(
      (value) => value === "1",
      () => false,
    );
  }
  return activation;
}

async function resolvePath($: EngineInterface): Promise<string> {
  if (pulsePath === undefined) {
    const state = fleetStateDirectory(
      {
        FM_HOME: await $.env.get("FM_HOME"),
        FM_ROOT_OVERRIDE: await $.env.get("FM_ROOT_OVERRIDE"),
        FM_STATE_OVERRIDE: await $.env.get("FM_STATE_OVERRIDE"),
      },
      $.plugin.root,
    );
    pulsePath = `${state}/.fleet-pulse.json`;
  }
  return pulsePath;
}

/** Re-read the pulse file when its size or time changed; redraw the pane when it did. */
async function poll($: EngineInterface): Promise<void> {
  const path = await resolvePath($);
  let current: string;
  let settled: boolean;
  try {
    // A missing file is checked first: every rejected stat or read is an error in Claude
    // Code's debug log, and the pulse may not exist until the sidecar first runs.
    if (!(await $.fs.exists(path))) {
      if (pulse !== undefined || stamp !== undefined) {
        pulse = undefined;
        stamp = undefined;
        $.ui.invalidate("ui.render");
      }
      return;
    }
    const stat = await $.fs.stat(path);
    current = `${stat.size}:${stat.mtimeMs}`;
    settled = (await $.clock.now()) - stat.mtimeMs >= SETTLED_MS;
    if (current === stamp) return;
    pulse = parsePulse(await $.fs.read(path));
  } catch {
    return;
  }
  stamp = settled ? current : undefined;
  $.ui.invalidate("ui.render");
}

async function openPane($: EngineInterface) {
  // columns apply when docked beside the transcript, rows when seated inline above the prompt.
  return $.ui.open({ id: PANE, title: TITLE, columns: PANE_COLUMNS, rows: PANE_ROWS });
}

function drawRows(Box: any, Text: any, rows: readonly Row[], width: number) {
  return (
    <Box flexDirection="column" width={width}>
      {rows.map((row) => (
        <Text>
          {row.spans.map((span) => (
            <Text color={span.color} bold={span.bold} dimColor={span.dim}>
              {span.text}
            </Text>
          ))}
        </Text>
      ))}
    </Box>
  );
}

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    await $.command.register({
      name: COMMAND,
      description: "Firstmate fleet pane: open or close the live worker cards",
      argumentHint: "[open|close|history [14|60]]",
    });
    historyDays = HISTORY_DEFAULT_DAYS;
    pulsePath = undefined;
    pulse = undefined;
    stamp = undefined;
    await poll($);
    // Each session start follows the file with one fresh timer.
    timer?.cancel();
    timer = $.clock.every(POLL_MS, () => {
      void poll($);
    });
    void openPane($).catch(() => undefined);
    return next(e);
  });

  on("command.run", { command: COMMAND }, async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    const [verb = "open", arg = ""] = String(e.args ?? "").trim().split(/\s+/);
    if (verb === "history") {
      // `/lookout history` cycles 3, 14 and 60 days; `3`, `14` or `60` (or `14d`) picks one.
      const days = parseInt(arg, 10);
      const known = HISTORY_WINDOWS.includes(days);
      if (arg !== "" && !known) {
        return { text: `Usage: /lookout history [${HISTORY_WINDOWS.join("|")}]; showing ${historyDays}d.` };
      }
      historyDays = known ? days : nextHistoryWindow(historyDays);
      $.ui.invalidate("ui.render");
      return { text: `Fleet history: last ${historyDays} days.` };
    }
    if (verb === "close") {
      await $.ui.close({ id: PANE });
      return { text: "Fleet pane closed." };
    }
    const opened = await openPane($);
    if (!opened.isPlaced) return { text: `Fleet pane is not shown yet: ${opened.reason}` };
    return { text: "Fleet pane opened. It needs a wide terminal to dock; /lookout close hides it." };
  }).catch(($, e, next) => ({ text: `Fleet pane failed (${next.error.kind}): ${next.error.message ?? "no message"}` }));

  on("ui.render", { component: "Pane", requestId: PANE }, async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    const { Box, Text } = $.ui.resolve(e);
    // The body's own width, down to the narrowest dock Claude Code seats (24).
    const width = Math.max(24, e.props.bodyColumns);
    const now = Math.floor((await $.clock.now()) / 1000);
    return drawRows(Box, Text, paneRows(pulse, now, width, historyDays), width);
  }).catch(($, e, next) => {
    // Without this a failed draw leaves the engine's empty pane.
    const { Box, Text } = $.ui.resolve(e);
    return (
      <Box flexDirection="column" width={Math.max(20, e.props.bodyColumns)}>
        <Text bold>FLEET</Text>
        <Text color="warning" wrap="wrap">{`draw failed (${next.error.kind}): ${next.error.message ?? "no message"}`}</Text>
      </Box>
    );
  });
};
