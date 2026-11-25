// The token breakdown drawn beside a cost: its compact form, the fleet total, and that a narrow
// pane gives it up (falling back to a dim line under the row) before it touches the dollar figure.
import { describe, expect, test } from "claude-code/testing";
import {
  headerRows,
  historyRows,
  type HistoryRow,
  parsePulse,
  costByModel,
  median,
  modelLabel,
  modelShareText,
  outcomeLabel,
  prNumber,
  windowSummary,
  rowsToText,
  sumBreakdowns,
  tokenParen,
  workerTableRows,
} from "../lib/fm-fleet-format.ts";

const NOW = 1_800_000_000;
const B = { input: 1_200_000, output: 310_000, cacheRead: 38_000_000, cacheWrite: 2_000_000 };

function pulseWith(breakdown: unknown, cost = 5.07, exact = false) {
  return parsePulse(
    JSON.stringify({
      version: 1,
      generated_at: NOW,
      counts: { busy: 1 },
      total_cost_usd: cost,
      workers: [
        {
          id: "fix-login",
          state: "busy",
          busy: true,
          model: "claude-opus-5-5",
          tokens_total: 41_510_000,
          cost_usd: cost,
          cost_estimate: !exact,
          tokens_breakdown: breakdown,
        },
      ],
      history: { ledger_since: null, rows: [] },
    }),
  );
}

describe("inline cost breakdown", () => {
  test("compact in/out/cache form, cache is reads plus writes", () => {
    expect(tokenParen(B)).toBe("(in 1.2M · out 310k · cache 40.0M)");
    expect(tokenParen(null)).toBe("");
  });

  test("fleet total sums every breakdown and ignores workers without one", () => {
    expect(sumBreakdowns([B, null, B])).toEqual({ input: 2_400_000, output: 620_000, cacheRead: 76_000_000, cacheWrite: 4_000_000 });
    expect(sumBreakdowns([null])).toBe(null);
  });

  test("wide pane: breakdown sits beside the cost, no separate line, ~ kept for estimates", () => {
    const pulse = pulseWith({ input: B.input, output: B.output, cache_read: B.cacheRead, cache_write: B.cacheWrite });
    if (pulse === undefined) throw new Error("pulse did not parse");
    const text = rowsToText(workerTableRows(pulse.workers, NOW, 200));
    expect(text).toContain("~$5.07  (in 1.2M · out 310k · cache 40.0M)");
    expect(text).not.toContain("cache read");
    expect(rowsToText(headerRows(pulse))).toContain("est. ~$5.07 (in 1.2M · out 310k · cache 40.0M)");
  });

  test("exact cost has no ~", () => {
    const pulse = pulseWith({ input: 1, output: 2, cache_read: 3, cache_write: 4 }, 2.5, true);
    if (pulse === undefined) throw new Error("pulse did not parse");
    expect(rowsToText(workerTableRows(pulse.workers, NOW, 200))).toContain(" $2.50  (in 1 · out 2 · cache 7)");
  });

  test("narrow pane: dollar figure intact, breakdown falls back to its own line", () => {
    const pulse = pulseWith({ input: B.input, output: B.output, cache_read: B.cacheRead, cache_write: B.cacheWrite });
    if (pulse === undefined) throw new Error("pulse did not parse");
    const text = rowsToText(workerTableRows(pulse.workers, NOW, 60));
    expect(text).toContain("~$5.07");
    expect(text).not.toContain("(in 1.2M");
    expect(text).toContain("tokens  in 1.2M  out 310k  cache read 38.0M  cache write 2.0M");
  });

  test("history rows share one breakdown column and fall back when narrow", () => {
    const row = (task: string, endedAt: number): HistoryRow => ({
      task,
      project: "p",
      model: "claude-sonnet-5-5",
      effort: "high",
      outcome: "merged",
      via: null,
      endedAt,
      durationS: 60,
      spendTokens: null,
      spendUnknown: 0,
      costUsd: 1.5,
      tokens: 1000,
      costExact: true,
      breakdown: { input: 100, output: 200, cacheRead: 300, cacheWrite: 400 },
      subagents: [],
      byModel: [],
      kind: "ship",
      pr: "",
    });
    const history = { ledgerSince: null, rows: [row("a", NOW - 60), row("b", NOW - 120)] };
    const wide = rowsToText(historyRows(history, NOW, 200, 14));
    expect(wide.split("(in 100 · out 200 · c.read 300 · c.write 400)").length - 1).toBe(2);
    expect(wide).not.toContain("────");
    const narrow = rowsToText(historyRows(history, NOW, 70, 14));
    expect(narrow).not.toContain("(in 100");
    expect(narrow).toContain("$1.50");
    expect(narrow).toContain("tokens  in 100");
    const withAgents = { ...history, rows: [{ ...history.rows[0]!, subagents: [{ type: "waiter-agent", model: "claude-haiku-5-5", effort: "low", agents: 1, tokens: 10, costUsd: 0.01 }] }, history.rows[1]!] };
    const ruled = rowsToText(historyRows(withAgents, NOW, 200, 14)).split("\n");
    expect(ruled.filter((l) => l.startsWith("────")).length).toBe(3);
  });

  test("tokenParen split names cache read and cache write", () => {
    expect(tokenParen(B, true)).toBe("(in 1.2M · out 310k · c.read 38.0M · c.write 2.0M)");
  });

  test("model and effort: label, history column, subagent rows, narrow fallback", () => {
    expect(modelLabel("claude-sonnet-5-5", "high")).toBe("sonnet 5.5 · high");
    expect(modelLabel("claude-opus-5-5", "")).toBe("opus 5.5");
    expect(modelLabel("claude-opus-5-5", "xhigh", 10)).toBe("opus 5.5");
    expect(modelLabel("", "high")).toBe("?");
    const row = {
      task: "a", project: "p", model: "claude-sonnet-5-5", effort: "high", outcome: "merged", via: null, endedAt: NOW - 60,
      durationS: 60, spendTokens: null, spendUnknown: 0, costUsd: 1.5, tokens: 1000, costExact: true, breakdown: null,
      byModel: [], kind: "ship", pr: "",
      subagents: [{ type: "waiter-agent", model: "claude-haiku-5-5", effort: "low", agents: 1, tokens: 10, costUsd: 0.01 }],
    } satisfies HistoryRow;
    const history = { ledgerSince: null, rows: [row, { ...row, task: "b", model: "", effort: "", subagents: [] }] };
    const wide = rowsToText(historyRows(history, NOW, 120, 14));
    expect(wide).toContain("MODEL");
    expect(wide).toContain("sonnet 5.5 · high");
    expect(wide).toContain("haiku 5.5 · low");
    const narrow = rowsToText(historyRows(history, NOW, 50, 14));
    expect(narrow).not.toContain("sonnet 5.5 · high");
    expect(narrow).toContain("$1.50");
    const pulse = parsePulse(JSON.stringify({ version: 1, generated_at: NOW, counts: {}, workers: [{ id: "w", state: "busy", model: "claude-opus-5-5", effort: "medium", cost_usd: 1 }], history: { rows: [] } }));
    if (pulse === undefined) throw new Error("pulse did not parse");
    expect(rowsToText(workerTableRows(pulse.workers, NOW, 120))).toContain("opus 5.5 · medium");
  });

  const base: HistoryRow = {
    task: "t", project: "p", model: "", effort: "", outcome: "cleaned_up", via: null, endedAt: NOW - 60, durationS: null,
    spendTokens: null, spendUnknown: 0, costUsd: null, tokens: null, costExact: false, breakdown: null, subagents: [], byModel: [], kind: "ship", pr: "",
  };
  const BB = "https://bitbucket.org/atlassian/ml-feature-store/pull-requests/3361";

  test("outcome label: merged #N, closed #N, PR #N, report, no PR", () => {
    expect(prNumber(BB)).toBe("#3361");
    expect(prNumber("https://github.com/a/b/pull/7")).toBe("#7");
    expect(prNumber("")).toBe("");
    expect(outcomeLabel({ ...base, outcome: "merged", via: "pr", pr: BB })).toBe("merged #3361");
    expect(outcomeLabel({ ...base, outcome: "merged", via: "local" })).toBe("merged local");
    expect(outcomeLabel({ ...base, outcome: "closed", via: "pr", pr: BB })).toBe("closed #3361");
    expect(outcomeLabel({ ...base, pr: BB })).toBe("PR #3361");
    expect(outcomeLabel({ ...base, kind: "scout" })).toBe("report");
    expect(outcomeLabel(base)).toBe("no PR");
  });

  test("history table shows an OUTCOME column that narrow panes drop after the task and cost", () => {
    const history = { ledgerSince: null, rows: [{ ...base, task: "a", outcome: "merged", via: "pr", pr: BB, costUsd: 2 }] };
    expect(rowsToText(historyRows(history, NOW, 140, 14))).toContain("merged #3361");
    const narrow = rowsToText(historyRows(history, NOW, 30, 14));
    expect(narrow).toContain("$2.00");
  });

  test("cost by model: grouped by short name, share of the total, costliest first, extras rolled up", () => {
    const src = [
      { byModel: [{ model: "claude-opus-5-5", tokens: 10, costUsd: 14 }, { model: "claude-sonnet-5-5", tokens: 10, costUsd: 6 }] },
      { byModel: [{ model: "claude-opus-5-5", tokens: 5, costUsd: 6 }, { model: "claude-haiku-5-5", tokens: 5, costUsd: 4 }] },
    ];
    expect(costByModel(src).map((m) => [m.name, m.costUsd])).toEqual([["opus 5.5", 20], ["sonnet 5.5", 6], ["haiku 5.5", 4]]);
    expect(modelShareText(src)).toBe("opus 5.5 $20.00 67% · sonnet 5.5 $6.00 20% · haiku 5.5 $4.00 13%");
    expect(modelShareText(src, 1)).toBe("opus 5.5 $20.00 67% · +2 other $10.00");
    expect(modelShareText([{ byModel: [] }])).toBe("");
  });

  test("window summary: merged count, spend, cost per merged task, median time to merge", () => {
    expect(median([])).toBe(null);
    expect(median([5, 1, 3])).toBe(3);
    expect(median([1, 3])).toBe(2);
    const rows: HistoryRow[] = [
      { ...base, task: "a", outcome: "merged", costUsd: 4, durationS: 3600 },
      { ...base, task: "b", outcome: "merged", costUsd: 2, durationS: 7200 },
      { ...base, task: "c", costUsd: 6, durationS: 100 },
    ];
    expect(windowSummary(rows)).toBe("3 finished · 2 merged · spend $12.00 · $3.00/merged · median 1h30m");
    expect(windowSummary([])).toBe("");
    const text = rowsToText(historyRows({ ledgerSince: null, rows: rows.map((r) => ({ ...r, byModel: [{ model: "claude-opus-5-5", tokens: 1, costUsd: r.costUsd ?? 0 }] })) }, NOW, 140, 14));
    expect(text).toContain("last 14d: 3 finished · 2 merged");
    expect(text).toContain("spend by model (history + live): opus 5.5 $12.00 100%");
  });
});
