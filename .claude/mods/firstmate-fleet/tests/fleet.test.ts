// firstmate-fleet under `claude plugin test`: the pure pulse parsing and card formatting,
// then the hooks module in the engine's own host against a mocked clock, environment,
// file system, and drawing surface.
import type { On } from "claude-code";
import { describe, expect, mock, test } from "claude-code/testing";
import {
  cardRows,
  fleetStateDirectory,
  filterHistory,
  fmtAge,
  fmtSpend,
  gauge,
  headerRows,
  historyRows,
  type HistoryRow,
  orderWorkers,
  paneRows,
  parsePulse,
  rowsToText,
  shorten,
  type Worker,
} from "../lib/fm-fleet-format.ts";

const NOW = 1_800_000_000;
const HOME = "/fm/home";
const PULSE = `${HOME}/state/.fleet-pulse.json`;

function worker(over: Partial<Worker> = {}): Worker {
  return {
    id: "rtfv-d2",
    kind: "ship",
    harness: "claude",
    model: "claude-opus-5-5",
    title: "flapuz/MLP-12354",
    state: "paused",
    busy: false,
    waitingOnCaptain: false,
    lastStatus: "Apply staging 500 server-side; firstmate investigating",
    lastStatusAt: NOW - 7200,
    lastEventAt: NOW - 7200,
    contextPct: 54,
    contextTokens: 108_000,
    contextWindow: 200_000,
    costUsd: 31.5632,
    ...over,
  };
}

function pulseJson(workers: unknown[], over: Record<string, unknown> = {}): string {
  return JSON.stringify({ version: 1, generated_at: NOW, workers, counts: {}, total_cost_usd: 0, ...over });
}

function rawWorker(over: Record<string, unknown> = {}) {
  return {
    id: "rtfv-d2",
    kind: "ship",
    harness: "claude",
    model: "claude-opus-5-5",
    title: "flapuz/MLP-12354",
    state: "paused",
    busy: false,
    waiting_on_captain: false,
    last_status: "Apply staging 500",
    last_status_at: NOW - 7200,
    last_event_at: NOW - 7200,
    context: { tokens: 108_000, window: 200_000, pct: 54, estimate: true },
    cost_usd: 31.5632,
    cost_estimate: true,
    ...over,
  };
}

describe("formatting helpers", () => {
  test("shorten collapses whitespace and cuts with an ellipsis", () => {
    expect(shorten("  a   b  ", 10)).toBe("a b");
    expect(shorten("abcdefghij", 5)).toBe("abcd…");
    expect(shorten("abc", 0)).toBe("");
  });

  test("gauge fills proportionally and clamps", () => {
    expect(gauge(50, 10)).toEqual({ on: "▰▰▰▰▰", off: "▱▱▱▱▱" });
    expect(gauge(0, 4)).toEqual({ on: "", off: "▱▱▱▱" });
    expect(gauge(250, 4)).toEqual({ on: "▰▰▰▰", off: "" });
  });

  test("fmtAge names the largest unit and is empty when unknown", () => {
    expect([fmtAge(NOW - 5, NOW), fmtAge(NOW - 600, NOW), fmtAge(NOW - 7200, NOW), fmtAge(NOW - 3 * 86400, NOW)]).toEqual([
      "5s",
      "10m",
      "2h",
      "3d",
    ]);
    expect([fmtAge(null, NOW), fmtAge(0, NOW), fmtAge(NOW + 5, NOW)]).toEqual(["", "", "0s"]);
  });

  test("the state directory follows FM_STATE_OVERRIDE, then the home, then the code root", () => {
    const root = "/code/.claude/mods/firstmate-fleet";
    expect(fleetStateDirectory({ FM_STATE_OVERRIDE: "/s" }, root)).toBe("/s");
    expect(fleetStateDirectory({ FM_HOME: "/h" }, root)).toBe("/h/state");
    expect(fleetStateDirectory({ FM_ROOT_OVERRIDE: "/r" }, root)).toBe("/r/state");
    expect(fleetStateDirectory({}, root)).toBe("/code/state");
  });
});

describe("pulse parsing", () => {
  test("a version 1 pulse parses into workers, counts, and the estimated total", () => {
    const pulse = parsePulse(pulseJson([rawWorker()], { counts: { paused: 1 }, total_cost_usd: 31.5632 }));
    expect(pulse?.workers).toHaveLength(1);
    expect(pulse?.workers[0]).toMatchObject({ id: "rtfv-d2", contextPct: 54, costUsd: 31.5632, state: "paused" });
    expect(pulse?.counts).toEqual({ paused: 1 });
    expect(pulse?.totalCostUsd).toBe(31.5632);
  });

  test("anything that is not a version 1 pulse is rejected, and bad workers are skipped", () => {
    expect(parsePulse(undefined)).toBeUndefined();
    expect(parsePulse("")).toBeUndefined();
    expect(parsePulse("{nope")).toBeUndefined();
    expect(parsePulse('{"version":2,"workers":[]}')).toBeUndefined();
    expect(parsePulse('{"version":1}')).toBeUndefined();
    const mixed = parsePulse(pulseJson([rawWorker(), { id: "" }, null, 7, rawWorker({ id: "b", context: null, cost_usd: null })]));
    expect(mixed?.workers.map((w) => w.id)).toEqual(["rtfv-d2", "b"]);
    expect(mixed?.workers[1]).toMatchObject({ contextPct: null, costUsd: null });
  });
});

describe("cards", () => {
  test("a card shows glyph, id, kind, state and age, title, last status, gauge and estimated cost", () => {
    const text = rowsToText(cardRows(worker(), NOW, 64));
    expect(text).toContain("◌ rtfv-d2 ship");
    expect(text).toContain("paused 2h");
    expect(text).toContain("flapuz/MLP-12354");
    expect(text).toContain("Apply staging 500 server-side");
    expect(text).toContain("~54%");
    expect(text).toContain("108k");
    expect(text).toContain("~$31.56");
    expect(text.split("\n")[0]?.length).toBe(64);
  });

  test("a worker with no transcript shows n/a instead of a guess", () => {
    const text = rowsToText(cardRows(worker({ contextPct: null, contextTokens: null, costUsd: null }), NOW, 64));
    expect(text).toContain("ctx n/a");
    expect(text).toContain("~$n/a");
  });

  test("a worker waiting on the captain draws its id and state in the error color", () => {
    const rows = cardRows(worker({ state: "needs-decision", waitingOnCaptain: true }), NOW, 64);
    const first = rows[0]!.spans;
    expect(first.find((s) => s.text === "rtfv-d2")?.color).toBe("error");
    expect(first[first.length - 1]).toMatchObject({ color: "error", bold: true });
  });

  test("a hot context gauge turns the error color at 85 percent", () => {
    const rows = cardRows(worker({ contextPct: 90 }), NOW, 64);
    expect(rows[rows.length - 1]!.spans.some((s) => s.color === "error" && s.text.startsWith("▰"))).toBe(true);
  });

  test("a narrow pane keeps every row inside its width", () => {
    for (const row of cardRows(worker({ title: "x".repeat(200), lastStatus: "y".repeat(200) }), NOW, 30)) {
      expect(row.spans.map((s) => s.text).join("").length).toBeLessThanOrEqual(30);
    }
  });

  test("cards order waiting-on-captain first, then live, then parked", () => {
    const ordered = orderWorkers([
      worker({ id: "c", state: "paused" }),
      worker({ id: "b", state: "busy" }),
      worker({ id: "a", state: "blocked", waitingOnCaptain: true }),
      worker({ id: "d", state: "idle" }),
    ]);
    expect(ordered.map((w) => w.id)).toEqual(["a", "b", "c", "d"]);
  });

  test("the header counts workers by state, totals the estimated cost, and flags captain waits", () => {
    const pulse = parsePulse(
      pulseJson([rawWorker({ state: "blocked", waiting_on_captain: true }), rawWorker({ id: "b", state: "busy" })], {
        counts: { blocked: 1, busy: 1 },
        total_cost_usd: 12.5,
      }),
    )!;
    const text = rowsToText(headerRows(pulse));
    expect(text).toContain("FLEET · 1 busy · 1 blocked");
    expect(text).toContain("2 workers · est. ~$12.50");
    expect(text).toContain("1 needs you");
  });

  test("an absent pulse says how to start the sidecar, and a stale one says so", () => {
    expect(rowsToText(paneRows(undefined, NOW, 64))).toContain("fm-fleet-pulse.sh");
    const stale = parsePulse(pulseJson([], { generated_at: NOW - 600 }))!;
    expect(rowsToText(paneRows(stale, NOW, 64))).toContain("pulse is 10m old");
  });
});

const DAY = 86400;
const done = (task: string, daysAgo: number, over: Partial<HistoryRow> = {}): HistoryRow => ({
  task,
  outcome: "merged",
  via: "pr",
  endedAt: NOW - daysAgo * DAY,
  durationS: 4800,
  spendTokens: 412_000,
  spendUnknown: 0,
  ...over,
});

describe("history", () => {
  test("the default 14 day window keeps recent tasks, the 60 day window adds older ones, and nothing older shows", () => {
    const rows = [done("recent", 3), done("edge", 14), done("older", 30), done("oldest", 59), done("gone", 61)];
    expect(filterHistory(rows, NOW, 14).map((r) => r.task)).toEqual(["recent", "edge"]);
    expect(filterHistory(rows, NOW, 60).map((r) => r.task)).toEqual(["recent", "edge", "older", "oldest"]);
    expect(filterHistory(rows, NOW, 14)[0]!.task).toBe("recent");
  });

  test("duplicate records for one task collapse to its newest", () => {
    const rows = [done("t", 5), done("t", 2), done("u", 4)];
    expect(filterHistory(rows, NOW, 14).map((r) => [r.task, r.endedAt])).toEqual([
      ["t", NOW - 2 * DAY],
      ["u", NOW - 4 * DAY],
    ]);
  });

  test("a row is one collapsed line: task, outcome, age, duration, spend", () => {
    const text = rowsToText(historyRows({ ledgerSince: NOW - 9 * DAY, rows: [done("fix-login", 2)] }, NOW, 70, 14));
    expect(text).toContain("HISTORY · last 14d · /lookout history 60 for 60d");
    expect(text).toContain("✓ fix-login merged pr 2d ago · 1h20m · 412k tok");
    expect(text.split("\n")).toHaveLength(2);
  });

  test("unknown spend shows a dash, a lower bound a plus, and a cleaned-up task its outcome", () => {
    expect([fmtSpend(null, 0), fmtSpend(1_200_000, 0), fmtSpend(5000, 2)]).toEqual(["-", "1.2M tok", "5k+ tok"]);
    const text = rowsToText(historyRows({ ledgerSince: null, rows: [done("x", 1, { outcome: "cleaned_up", via: null, durationS: null, spendTokens: null })] }, NOW, 70, 14));
    expect(text).toContain("· x cleaned up 1d ago · - · -");
  });

  test("an empty or absent ledger shows the empty-state line, naming when records began", () => {
    expect(rowsToText(historyRows({ ledgerSince: null, rows: [] }, NOW, 70, 14))).toContain("no finished tasks in the last 14d (no ledger yet)");
    const since = Date.parse("2026-11-02T00:00:00Z") / 1000;
    expect(rowsToText(historyRows({ ledgerSince: since, rows: [] }, NOW, 70, 60))).toContain("no finished tasks in the last 60d (ledger records since 2026-11-02)");
  });

  test("a long history is capped with a count of the rest", () => {
    const rows = Array.from({ length: 30 }, (_, i) => done(`t${i}`, 1));
    expect(rowsToText(historyRows({ ledgerSince: null, rows }, NOW, 70, 14))).toContain("+5 more");
  });

  test("the pulse parser reads history rows and tolerates their absence or damage", () => {
    const withHistory = parsePulse(
      pulseJson([], { history: { ledger_since: 5, rows: [{ task: "a", outcome: "merged", via: "local", ended_at: 9, duration_s: 3, spend_tokens: 7, spend_unknown: 1 }, { task: "" }, { task: "b" }, 3] } }),
    )!;
    expect(withHistory.history.ledgerSince).toBe(5);
    expect(withHistory.history.rows).toEqual([{ task: "a", outcome: "merged", via: "local", endedAt: 9, durationS: 3, spendTokens: 7, spendUnknown: 1 }]);
    expect(parsePulse(pulseJson([]))!.history).toEqual({ ledgerSince: null, rows: [] });
    expect(parsePulse(pulseJson([], { history: "nope" }))!.history.rows).toEqual([]);
  });

  test("the pane puts the history below the cards", () => {
    const pulse = parsePulse(pulseJson([rawWorker()], { history: { ledger_since: 1, rows: [{ task: "old-one", outcome: "merged", via: "pr", ended_at: NOW - DAY }] } }))!;
    const text = rowsToText(paneRows(pulse, NOW, 70));
    expect(text.indexOf("rtfv-d2")).toBeLessThan(text.indexOf("HISTORY"));
    expect(text.indexOf("HISTORY")).toBeLessThan(text.indexOf("old-one"));
  });
});

// ---------------------------------------------------------------- engine

const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };

function engine(on: On, options: { functionHooks?: string | undefined } = { functionHooks: "1" }) {
  mock.env(on, {
    FM_HOME: HOME,
    ...(options.functionHooks === undefined ? {} : { CLAUDE_CODE_ENABLE_FUNCTION_HOOKS: options.functionHooks }),
  });
  const clock = mock.clock(on);
  const files = new Map<string, string>();
  const journal = { commands: [] as string[], invalidations: [] as string[], opens: [] as { id: string; columns?: number }[], reads: 0 };
  on("fs.read", async (_$, e) => {
    journal.reads += 1;
    return files.has(e.path) ? { value: files.get(e.path)! } : { deny: `ENOENT: ${e.path}` };
  });
  on("fs.exists", async (_$, e) => ({ value: files.has(e.path) }));
  on("fs.stat", async (_$, e) => {
    const text = files.get(e.path);
    if (text === undefined) return { deny: `ENOENT: ${e.path}` };
    // Long before the mocked now, so it counts as settled; size restamps changed content.
    return { value: { kind: "file" as const, size: text.length, mtimeMs: -1_000_000 } };
  });
  on("session.start", async (_$, e) => ({ cwd: e.cwd }));
  on("command.register", async (_$, e) => {
    journal.commands.push(e.name);
    return { value: { command: e.name } };
  });
  on("ui.invalidate", async (_$, e) => {
    journal.invalidations.push(e.event);
    return { value: undefined };
  });
  on("ui.open", async (_$, e) => {
    journal.opens.push({ id: e.id, columns: e.columns });
    return { value: { isPlaced: true as const } };
  });
  on("ui.render", async () => ({ type: "Text", props: {}, children: ["STOCK"] }));
  return { clock, files, journal };
}

const pane = (bodyColumns: number) => ({
  plugin: "fmfleet",
  component: "Pane" as const,
  requestId: "fleet",
  props: {
    title: "Fleet",
    isFocused: true,
    bodyColumns,
    placement: "dock" as const,
    scroll: { offset: 0, bodyRows: 70 },
    view: {},
  },
});

describe("the mod in the engine", () => {
  async function expectInert($: Parameters<Parameters<typeof test>[1]>[0], on: On, functionHooks: string | undefined) {
    const { clock, files, journal } = engine(on, { functionHooks });
    files.set(PULSE, pulseJson([rawWorker()]));
    await $.session.start(sessionStart);
    await clock.advance(2000 * 4);
    expect(journal.commands).toHaveLength(0);
    expect(journal.invalidations).toHaveLength(0);
    expect(journal.opens).toHaveLength(0);
    expect(journal.reads).toBe(0);
  }

  test("is fully inert when the function-hooks opt-in is absent", async ($, on) => {
    await expectInert($, on, undefined);
  });

  test("is fully inert when the function-hooks opt-in is not exactly one", async ($, on) => {
    await expectInert($, on, "true");
  });

  test("registers /lookout and opens the docked pane at session start", async ($, on) => {
    const { journal } = engine(on);
    await $.session.start(sessionStart);
    expect(journal.commands).toEqual(["lookout"]);
    expect(journal.opens).toEqual([{ id: "fleet", columns: 66 }]);
  });

  test("draws one card per worker from the pulse file and follows changes without rereading unchanged files", async ($, on) => {
    const { clock, files, journal } = engine(on);
    files.set(PULSE, pulseJson([rawWorker()], { counts: { paused: 1 }, total_cost_usd: 31.5632 }));
    await $.session.start(sessionStart);
    const first = await $.ui.mount({ ...pane(64), surface: "terminal" });
    expect(await first.find({ text: /rtfv-d2/ })).toBeDefined();
    expect(await first.find({ text: /~\$31\.56/ })).toBeDefined();
    await first.unmount();
    const reads = journal.reads;
    await clock.advance(2000 * 3);
    expect(journal.reads).toBe(reads);
    files.set(PULSE, pulseJson([rawWorker(), rawWorker({ id: "second-worker" })], { counts: { paused: 2 }, total_cost_usd: 40 }));
    await clock.advance(2000);
    expect(journal.invalidations).toContain("ui.render");
    const second = await $.ui.mount({ ...pane(64), surface: "terminal" });
    expect(await second.find({ text: /second-worker/ })).toBeDefined();
    await second.unmount();
  });

  test("says how to start the sidecar while no pulse file exists", async ($, on) => {
    engine(on);
    await $.session.start(sessionStart);
    const ui = await $.ui.mount({ ...pane(64), surface: "terminal" });
    expect(await ui.find({ text: /fm-fleet-pulse\.sh/ })).toBeDefined();
    await ui.unmount();
  });

  test("a garbled pulse file draws as no pulse and never throws", async ($, on) => {
    const { files } = engine(on);
    files.set(PULSE, "{not json");
    await $.session.start(sessionStart);
    const ui = await $.ui.mount({ ...pane(64), surface: "terminal" });
    expect(await ui.find({ text: /fm-fleet-pulse\.sh/ })).toBeDefined();
    await ui.unmount();
  });

  test("/lookout history shows 14 days by default and flips to 60 on demand", async ($, on) => {
    const { clock, files } = engine(on);
    await clock.set(NOW * 1000);
    const nowS = NOW;
    const recent = { task: "week-old", outcome: "merged", via: "pr", ended_at: nowS - 3 * DAY };
    const old = { task: "month-old", outcome: "merged", via: "pr", ended_at: nowS - 30 * DAY };
    files.set(PULSE, pulseJson([], { generated_at: nowS, history: { ledger_since: 1, rows: [recent, old] } }));
    await $.session.start(sessionStart);
    const seen = async () => {
      const ui = await $.ui.mount({ ...pane(70), surface: "terminal" });
      const result = {
        recent: (await ui.find({ text: /week-old/ })) !== undefined,
        old: (await ui.find({ text: /month-old/ })) !== undefined,
      };
      await ui.unmount();
      return result;
    };
    const run = (args: string) =>
      $.command.run({ command: "lookout", args, origin: { kind: "composer" as const }, presentation: { layout: "main" as const, isFullscreen: false, columns: 80 } });
    expect(await seen(), 'step1').toEqual({ recent: true, old: false });
    expect(await run("history")).toMatchObject({ text: expect.stringContaining("last 60 days") });
    expect(await seen(), 'step2').toEqual({ recent: true, old: true });
    expect(await run("history 14")).toMatchObject({ text: expect.stringContaining("last 14 days") });
    expect(await seen(), 'step3').toEqual({ recent: true, old: false });
    expect(await run("history 7")).toMatchObject({ text: expect.stringContaining("Usage") });
    expect(await seen(), 'step4').toEqual({ recent: true, old: false });
  });
});
