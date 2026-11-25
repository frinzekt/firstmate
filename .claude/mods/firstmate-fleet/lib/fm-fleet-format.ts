// Pure data and formatting for the Firstmate fleet pane: the pulse file parser and the
// worker cards. Nothing here touches `$`, so every behavior is testable under Node.
//
// The helpers `shorten`, `kTokens`, `fmtDuration`, `fmtUsd`, and `gauge` are adapted from
// claude-flightdeck (https://github.com/scasella/claude-flightdeck, hooks/core.ts),
// MIT License, Copyright (c) 2026 Stephen Casella. The licence text is in ../LICENSE-flightdeck.
//
// The pulse file (state/.fleet-pulse.json) is written by bin/fm-fleet-pulse.sh, which owns
// its schema. Context percentages and costs in it are estimates and are drawn with a `~`.

/** What one worker's subagents spent on one model (bin/fm-fleet-pulse.sh owns the schema). */
export type SubagentUse = { type: string; model: string; effort: string; agents: number; tokens: number; costUsd: number };

/** What one task spent on one model, main session and subagents together (bin/fm-fleet-pulse.sh owns the schema). */
export type ModelUse = { model: string; tokens: number; costUsd: number };

/** Token counts behind a cost (bin/fm-fleet-pulse.sh owns the schema). */
export type TokenBreakdown = { input: number; output: number; cacheRead: number; cacheWrite: number };

export type Worker = {
  id: string;
  kind: string;
  harness: string;
  model: string;
  effort: string;
  title: string;
  state: string;
  busy: boolean;
  waitingOnCaptain: boolean;
  lastStatus: string;
  lastStatusAt: number | null;
  lastEventAt: number | null;
  startedAt: number | null;
  display: string;
  project: string;
  tokensTotal: number | null;
  subagents: SubagentUse[];
  byModel: ModelUse[];
  stageLabel: string;
  stageStep: number | null;
  stageTotal: number | null;
  contextPct: number | null;
  contextTokens: number | null;
  contextWindow: number | null;
  costUsd: number | null;
  costExact: boolean;
  breakdown: TokenBreakdown | null;
};

/** One finished task of the history section (bin/fm-fleet-pulse.sh owns the schema). */
export type HistoryRow = {
  task: string;
  project: string;
  model: string;
  effort: string;
  outcome: string;
  via: string | null;
  endedAt: number;
  durationS: number | null;
  spendTokens: number | null;
  spendUnknown: number;
  costUsd: number | null;
  tokens: number | null;
  costExact: boolean;
  breakdown: TokenBreakdown | null;
  subagents: SubagentUse[];
  byModel: ModelUse[];
  /** `ship` or `scout`, from the ledger's dispatch record; empty when unknown. */
  kind: string;
  /** The PR link any ledger record carried; empty when none was ever recorded. */
  pr: string;
};

export type History = { ledgerSince: number | null; rows: HistoryRow[] };

/** The windows the history can show, in days: the default and the on-demand longer view. */
export const HISTORY_DEFAULT_DAYS = 3;
export const HISTORY_LONG_DAYS = 14;
/** Every window the history can show, shortest first; `/lookout history` cycles through them. */
export const HISTORY_WINDOWS: readonly number[] = [3, 14, 60];
export const nextHistoryWindow = (days: number): number =>
  HISTORY_WINDOWS[(HISTORY_WINDOWS.indexOf(days) + 1) % HISTORY_WINDOWS.length] ?? HISTORY_DEFAULT_DAYS;
/** Most history rows drawn at once; the rest are counted. */
export const HISTORY_MAX_ROWS = 25;

/** One backlog item that is not launched yet (bin/fm-fleet-pulse.sh owns the schema). */
export type QueueItem = {
  id: string;
  title: string;
  repo: string;
  kind: string;
  since: string;
  held: boolean;
  blockedBy: string[];
};

/** One backlog item with its dependency links (bin/fm-fleet-pulse.sh owns the schema). */
export type GraphItem = {
  id: string;
  title: string;
  section: string;
  held: boolean;
  blockedBy: string[];
  softAfter: string[];
};

export type Pulse = {
  generatedAt: number;
  queue: QueueItem[];
  graph: GraphItem[];
  history: History;
  workers: Worker[];
  counts: Record<string, number>;
  totalCostUsd: number;
};

/** A drawn piece of text; `color` is a Claude Code theme color name. */
export type Span = { text: string; color?: string; bold?: boolean; dim?: boolean };
export type Row = { spans: Span[] };

export const shorten = (s: string, n: number): string => {
  const one = s.replace(/\s+/g, " ").trim();
  return n <= 0 ? "" : one.length > n ? `${one.slice(0, Math.max(0, n - 1)).trimEnd()}…` : one;
};

export const kTokens = (n: number): string =>
  n >= 1_000_000 ? `${(n / 1_000_000).toFixed(1)}M` : n >= 1000 ? `${Math.round(n / 1000)}k` : String(n);

export const fmtDuration = (ms: number): string => {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  return m < 60 ? `${m}m${String(s % 60).padStart(2, "0")}s` : `${Math.floor(m / 60)}h${String(m % 60).padStart(2, "0")}m`;
};

export const fmtUsd = (n: number): string => (n >= 100 ? `$${Math.round(n)}` : `$${n.toFixed(2)}`);

/** A gauge of `width` cells: ▰ filled, ▱ empty. */
export const gauge = (pct: number, width: number): { on: string; off: string } => {
  const full = Math.max(0, Math.min(width, Math.round((pct / 100) * width)));
  return { on: "▰".repeat(full), off: "▱".repeat(width - full) };
};

/** How long ago an event was, in its largest unit: `45s`, `12m`, `3h`, `2d`; empty when unknown. */
export const fmtAge = (epochSeconds: number | null, nowSeconds: number): string => {
  if (epochSeconds === null || epochSeconds <= 0) return "";
  const s = Math.max(0, nowSeconds - epochSeconds);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
};

const asNumber = (value: unknown): number | null =>
  typeof value === "number" && Number.isFinite(value) ? value : null;
const asString = (value: unknown): string => (typeof value === "string" ? value : "");

function parseSubagents(value: unknown): SubagentUse[] {
  if (!Array.isArray(value)) return [];
  const out: SubagentUse[] = [];
  for (const item of value) {
    if (item === null || typeof item !== "object") continue;
    const r = item as Record<string, unknown>;
    const model = asString(r.model);
    if (model === "") continue;
    out.push({ type: asString(r.type) || "agent", model, effort: asString(r.effort), agents: asNumber(r.agents) ?? 0, tokens: asNumber(r.tokens) ?? 0, costUsd: asNumber(r.cost) ?? 0 });
  }
  return out;
}

function parseByModel(value: unknown): ModelUse[] {
  if (!Array.isArray(value)) return [];
  const out: ModelUse[] = [];
  for (const item of value) {
    if (item === null || typeof item !== "object") continue;
    const r = item as Record<string, unknown>;
    const model = asString(r.model);
    if (model === "") continue;
    out.push({ model, tokens: asNumber(r.tokens) ?? 0, costUsd: asNumber(r.cost) ?? 0 });
  }
  return out;
}

function parseWorker(value: unknown): Worker | undefined {
  if (value === null || typeof value !== "object") return undefined;
  const w = value as Record<string, unknown>;
  const id = asString(w.id);
  if (id === "") return undefined;
  const ctx = w.context !== null && typeof w.context === "object" ? (w.context as Record<string, unknown>) : {};
  const stage = w.stage !== null && typeof w.stage === "object" ? (w.stage as Record<string, unknown>) : {};
  return {
    id,
    kind: asString(w.kind),
    harness: asString(w.harness),
    model: asString(w.model),
    effort: asString(w.effort),
    title: asString(w.title),
    state: asString(w.state) || "unknown",
    busy: w.busy === true,
    waitingOnCaptain: w.waiting_on_captain === true,
    lastStatus: asString(w.last_status),
    lastStatusAt: asNumber(w.last_status_at),
    lastEventAt: asNumber(w.last_event_at),
    startedAt: asNumber(w.started_at),
    display: asString(w.display),
    project: asString(w.project),
    tokensTotal: asNumber(w.tokens_total),
    subagents: parseSubagents(w.subagents),
    byModel: parseByModel(w.by_model),
    stageLabel: asString(stage.label),
    stageStep: asNumber(stage.step),
    stageTotal: asNumber(stage.total),
    contextPct: asNumber(ctx.pct),
    contextTokens: asNumber(ctx.tokens),
    contextWindow: asNumber(ctx.window),
    costUsd: asNumber(w.cost_usd),
    costExact: w.cost_estimate === false,
    breakdown: parseBreakdown(w.tokens_breakdown),
  };
}

function parseBreakdown(value: unknown): TokenBreakdown | null {
  if (value === null || typeof value !== "object") return null;
  const b = value as Record<string, unknown>;
  return { input: asNumber(b.input) ?? 0, output: asNumber(b.output) ?? 0, cacheRead: asNumber(b.cache_read) ?? 0, cacheWrite: asNumber(b.cache_write) ?? 0 };
}

/**
 * The tokens behind a cost, `(in 1.2M · out 310k · cache 40M)`, where cache is reads plus writes,
 * or with `split` `(in 1.2M · out 310k · c.read 38M · c.write 2.0M)`; empty without a breakdown.
 */
export function tokenParen(b: TokenBreakdown | null, split = false): string {
  if (b === null) return "";
  const cache = split ? `c.read ${kTokens(b.cacheRead)} · c.write ${kTokens(b.cacheWrite)}` : `cache ${kTokens(b.cacheRead + b.cacheWrite)}`;
  return `(in ${kTokens(b.input)} · out ${kTokens(b.output)} · ${cache})`;
}

/** The fleet's tokens: every breakdown summed, or null when no worker has one. */
export function sumBreakdowns(list: readonly (TokenBreakdown | null)[]): TokenBreakdown | null {
  const have = list.filter((b): b is TokenBreakdown => b !== null);
  if (have.length === 0) return null;
  return have.reduce((t, b) => ({
    input: t.input + b.input,
    output: t.output + b.output,
    cacheRead: t.cacheRead + b.cacheRead,
    cacheWrite: t.cacheWrite + b.cacheWrite,
  }), { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
}

/**
 * One dim line with the tokens behind a cost, the fallback when the pane is too narrow for them
 * beside the cost; nothing when there is no breakdown.
 */
export function breakdownRows(b: TokenBreakdown | null): Row[] {
  if (b === null) return [];
  return [{ spans: [{ text: `  tokens  in ${kTokens(b.input)}  out ${kTokens(b.output)}  cache read ${kTokens(b.cacheRead)}  cache write ${kTokens(b.cacheWrite)}`, dim: true }] }];
}

function parseHistory(value: unknown): History {
  const empty: History = { ledgerSince: null, rows: [] };
  if (value === null || typeof value !== "object") return empty;
  const h = value as Record<string, unknown>;
  const rows: HistoryRow[] = [];
  if (Array.isArray(h.rows)) {
    for (const item of h.rows) {
      if (item === null || typeof item !== "object") continue;
      const r = item as Record<string, unknown>;
      const task = asString(r.task);
      const endedAt = asNumber(r.ended_at);
      if (task === "" || endedAt === null) continue;
      rows.push({
        task,
        project: asString(r.project),
        model: asString(r.model),
        effort: asString(r.effort),
        outcome: asString(r.outcome) || "cleaned_up",
        via: typeof r.via === "string" ? r.via : null,
        endedAt,
        durationS: asNumber(r.duration_s),
        spendTokens: asNumber(r.spend_tokens),
        spendUnknown: asNumber(r.spend_unknown) ?? 0,
        costUsd: asNumber(r.cost_usd),
        tokens: asNumber(r.tokens),
        costExact: r.cost_exact === true,
        breakdown: parseBreakdown(r.tokens_breakdown),
        subagents: parseSubagents(r.subagents),
        byModel: parseByModel(r.by_model),
        kind: asString(r.kind),
        pr: asString(r.pr),
      });
    }
  }
  return { ledgerSince: asNumber(h.ledger_since), rows };
}

function parseQueue(value: unknown): QueueItem[] {
  if (!Array.isArray(value)) return [];
  const out: QueueItem[] = [];
  for (const item of value) {
    if (item === null || typeof item !== "object") continue;
    const r = item as Record<string, unknown>;
    const id = asString(r.id);
    if (id === "") continue;
    out.push({
      id,
      title: asString(r.title),
      repo: asString(r.repo),
      kind: asString(r.kind),
      since: asString(r.since),
      held: r.held === true,
      blockedBy: Array.isArray(r.blocked_by) ? r.blocked_by.filter((b): b is string => typeof b === "string") : [],
    });
  }
  return out;
}

function parseGraph(value: unknown): GraphItem[] {
  if (!Array.isArray(value)) return [];
  const strings = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
  const out: GraphItem[] = [];
  for (const item of value) {
    if (item === null || typeof item !== "object") continue;
    const r = item as Record<string, unknown>;
    const id = asString(r.id);
    if (id === "") continue;
    out.push({
      id,
      title: asString(r.title),
      section: asString(r.section),
      held: r.held === true,
      blockedBy: strings(r.blocked_by),
      softAfter: strings(r.soft_after),
    });
  }
  return out;
}

/** The pulse a JSON text carries, or undefined when it is not a version 1 pulse. */
export function parsePulse(text: string | undefined): Pulse | undefined {
  if (text === undefined || text.trim() === "") return undefined;
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return undefined;
  }
  if (value === null || typeof value !== "object") return undefined;
  const p = value as Record<string, unknown>;
  if (p.version !== 1 || !Array.isArray(p.workers)) return undefined;
  const workers: Worker[] = [];
  for (const item of p.workers) {
    const worker = parseWorker(item);
    if (worker !== undefined) workers.push(worker);
  }
  const counts: Record<string, number> = {};
  if (p.counts !== null && typeof p.counts === "object") {
    for (const [key, n] of Object.entries(p.counts as Record<string, unknown>)) {
      const count = asNumber(n);
      if (count !== null) counts[key] = count;
    }
  }
  return {
    generatedAt: asNumber(p.generated_at) ?? 0,
    history: parseHistory(p.history),
    queue: parseQueue(p.queue),
    graph: parseGraph(p.graph),
    workers,
    counts,
    totalCostUsd: asNumber(p.total_cost_usd) ?? 0,
  };
}

/** Theme color names (the person's own theme) for each state. */
const STATE_COLOR: Record<string, string> = {
  busy: "success",
  idle: "inactive",
  paused: "warning",
  blocked: "error",
  "needs-decision": "error",
  failed: "error",
  done: "success",
  unknown: "inactive",
};
const STATE_GLYPH: Record<string, string> = {
  busy: "●",
  idle: "○",
  paused: "◌",
  blocked: "■",
  "needs-decision": "▲",
  failed: "✗",
  done: "✓",
  unknown: "?",
};
/** Cards sort captain-actionable first, then live, then waiting. */
const STATE_RANK: Record<string, number> = {
  "needs-decision": 0,
  blocked: 1,
  failed: 2,
  busy: 3,
  paused: 4,
  idle: 5,
  done: 6,
  unknown: 7,
};

export const stateColor = (state: string): string => STATE_COLOR[state] ?? "inactive";
export const stateGlyph = (state: string): string => STATE_GLYPH[state] ?? "?";

/** Workers in card order: waiting-on-captain first, then by state rank, then id. */
export function orderWorkers(workers: readonly Worker[]): Worker[] {
  return [...workers].sort(
    (a, b) =>
      Number(b.waitingOnCaptain) - Number(a.waitingOnCaptain) ||
      (STATE_RANK[a.state] ?? 9) - (STATE_RANK[b.state] ?? 9) ||
      a.id.localeCompare(b.id),
  );
}

/** The view's own name, shown in every header so the pane says where it comes from. */
export const VIEW_NAME = "/lookout";

/** `sonnet 5.5` from `claude-sonnet-5-5`; other names pass through minus a `claude-` prefix. */
export const shortModel = (model: string): string =>
  model === "" ? "?" : model.replace(/^claude-/, "").replace(/-(\d+)-(\d+)$/, " $1.$2").replace(/-/g, " ");

/**
 * `sonnet 5.5 · high`: the short model name plus its reasoning effort when one is recorded. When
 * `width` is given and the full label does not fit, the effort goes first, then the model is cut.
 */
export const modelLabel = (model: string, effort: string, width = Infinity): string => {
  const name = shortModel(model);
  const full = effort === "" || model === "" ? name : `${name} · ${effort}`;
  return full.length <= width ? full : shorten(name, width);
};

/** How long a worker has been open, in two units: `5d 2h`, `3h 12m`, `8m`; `-` when unknown. */
export const fmtOpen = (startedAt: number | null, nowSeconds: number): string => {
  if (startedAt === null || startedAt <= 0) return "-";
  const s = Math.max(0, nowSeconds - startedAt);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
};

const pad = (text: string, n: number): string => (text.length >= n ? text.slice(0, n) : text + " ".repeat(n - text.length));
const padLeft = (text: string, n: number): string => (text.length >= n ? text.slice(0, n) : " ".repeat(n - text.length) + text);
const GAP = "   ";

/** The break between two sections: a blank row, the heavy rule, then another blank row. */
export const sectionBreak = (width: number): Row[] => [{ spans: [{ text: "" }] }, ruleRow(width, true), { spans: [{ text: "" }] }];

/** A separator row: heavy (`━`) between sections, light (`─`) between workers. */
export const ruleRow = (width: number, heavy = false): Row => ({
  spans: [{ text: (heavy ? "━" : "─").repeat(Math.max(10, Math.min(width, 160))), dim: true }],
});

/** The header rows: the view name, counts by state, then the estimated total cost. */
export function headerRows(pulse: Pulse, nowSeconds: number = pulse.generatedAt): Row[] {
  const order = ["busy", "paused", "blocked", "needs-decision", "failed", "idle", "done", "unknown"];
  const spans: Span[] = [{ text: `FLEET ${VIEW_NAME}`, bold: true }];
  for (const state of order) {
    const n = pulse.counts[state];
    if (n === undefined || n === 0) continue;
    spans.push({ text: " · ", dim: true });
    spans.push({ text: `${n} ${state}`, color: stateColor(state) });
  }
  const rows: Row[] = [{ spans }];
  const waiting = pulse.workers.filter((w) => w.waitingOnCaptain).length;
  const total = tokenParen(sumBreakdowns(pulse.workers.map((w) => w.breakdown)));
  const tail: Span[] = [
    { text: `${pulse.workers.length} workers · est. ~${fmtUsd(pulse.totalCostUsd)}${total === "" ? "" : ` ${total}`} · data ${fmtAge(pulse.generatedAt, nowSeconds) || "0s"} old`, dim: true },
  ];
  if (waiting > 0) tail.push({ text: ` · ${waiting} need${waiting === 1 ? "s" : ""} you`, color: "error", bold: true });
  rows.push({ spans: tail });
  return rows;
}

/** Step dots for a worker's stage: `●●○○` is step 2 of 4. Empty when the stage is unknown. */
export const stageDots = (step: number | null, total: number | null): string =>
  step === null || total === null || total <= 0 ? "" : "●".repeat(Math.min(step, total)) + "○".repeat(Math.max(0, total - step));

/** One table column: its header, width, alignment, and keep-priority when the pane is narrow (1 = keep first). */
type Col = { key: string; head: string; width: number; right?: boolean; prio: number };
const COL_GAP = "  ";

/**
 * The columns that fit `width`, in display order. Columns are admitted by priority until the pane
 * is full, so a narrow pane drops the least important ones (never the task and the cost).
 */
function fitColumns(order: readonly Col[], width: number): Col[] {
  const kept = new Set<string>();
  let used = 0;
  for (const col of [...order].sort((x, y) => x.prio - y.prio)) {
    const need = col.width + (kept.size === 0 ? 0 : COL_GAP.length);
    if (kept.size >= 2 && used + need > width) continue;
    kept.add(col.key);
    used += need;
  }
  return order.filter((c) => kept.has(c.key));
}

/**
 * `cols` with the token-breakdown column right after COST when the pane still has room for the
 * longest breakdown in `parens`; it is the first thing a narrow pane gives up, so the dollar
 * figure is never truncated for it. `inline` says whether the column was added.
 */
function withBreakdown(cols: Col[], width: number, parens: readonly string[]): { cols: Col[]; inline: boolean } {
  const extra = Math.max(0, ...parens.map((p) => p.length));
  if (extra === 0) return { cols, inline: false };
  const used = cols.reduce((n, c, i) => n + c.width + (i === 0 ? 0 : COL_GAP.length), 0);
  if (used + COL_GAP.length + extra > width) return { cols, inline: false };
  const at = cols.findIndex((c) => c.key === "cost") + 1;
  return { cols: [...cols.slice(0, at), { key: "breakdown", head: "", width: extra, prio: Number.MAX_SAFE_INTEGER }, ...cols.slice(at)], inline: true };
}

const cell = (col: Col, text: string): string => (col.right ? padLeft(text, col.width) : pad(text, col.width));

/** A row from per-column spans: each span list is padded to its column's width, columns joined by a gap. */
function tableRow(cols: readonly Col[], cells: Record<string, Span[]>): Row {
  const spans: Span[] = [];
  cols.forEach((col, i) => {
    if (i > 0) spans.push({ text: COL_GAP });
    const parts = cells[col.key] ?? [{ text: "" }];
    const len = parts.reduce((n, s) => n + s.text.length, 0);
    const fill = Math.max(0, col.width - len);
    if (col.right && fill > 0) spans.push({ text: " ".repeat(fill) });
    spans.push(...parts);
    if (!col.right && fill > 0) spans.push({ text: " ".repeat(fill) });
  });
  return { spans };
}

/** Greedy word wrap to `width` columns, at most `maxLines` lines; the last line ends in `…` when text was cut. */
export function wrapText(text: string, width: number, maxLines: number): string[] {
  const words = text.replace(/\s+/g, " ").trim().split(" ").filter((w) => w !== "");
  const lines: string[] = [];
  let line = "";
  for (let word of words) {
    while (word.length > width) {
      if (line !== "") {
        lines.push(line);
        line = "";
      }
      lines.push(word.slice(0, width));
      word = word.slice(width);
    }
    if (line === "") line = word;
    else if (line.length + 1 + word.length <= width) line += ` ${word}`;
    else {
      lines.push(line);
      line = word;
    }
  }
  if (line !== "") lines.push(line);
  if (lines.length <= maxLines) return lines.length === 0 ? [""] : lines;
  const kept = lines.slice(0, maxLines);
  const last = kept[maxLines - 1] ?? "";
  kept[maxLines - 1] = `${last.slice(0, Math.max(0, width - 1)).trimEnd()}…`;
  return kept;
}

/**
 * Table rows for one record whose `wrapKey` cell wraps over several lines: the first line carries
 * every cell, and each continuation line carries only the wrapped text, so a long title takes
 * vertical space instead of being cut off.
 */
function wrappedRows(cols: readonly Col[], cells: Record<string, Span[]>, wrapKey: string, text: string, style: Partial<Span>, maxLines: number): Row[] {
  const col = cols.find((c) => c.key === wrapKey);
  const lines = wrapText(text, col?.width ?? 20, maxLines);
  return lines.map((line, i) =>
    tableRow(cols, i === 0 ? { ...cells, [wrapKey]: [{ text: line, ...style }] } : { [wrapKey]: [{ text: line, ...style }] }),
  );
}

const headerRow = (cols: readonly Col[]): Row =>
  tableRow(
    cols,
    Object.fromEntries(cols.map((c) => [c.key, [{ text: shorten(c.head, c.width), dim: true, bold: true }]])),
  );

/** The short word a stage column shows. */
const stageWord = (label: string, state: string): string =>
  label === "" ? state : label === "PR awaiting merge" ? "PR · merge" : label;

/**
 * The subagent sub-table: a header row, then one row per agent type and model (runs, tokens,
 * cost), indented under its worker. `none` when no subagent ran.
 */
export function subagentRows(subagents: readonly SubagentUse[], width: number): Row[] {
  if (subagents.length === 0) return [{ spans: [{ text: "  agents  none", dim: true }] }];
  const mw = width >= 72 ? 19 : 10;
  const tw = Math.max(12, Math.min(26, width - 34 - mw));
  const line = (a: string, m: string, r: string, tk: string, c: string): string =>
    `  ${pad(a, tw)}  ${pad(m, mw)}  ${padLeft(r, 4)}  ${padLeft(tk, 7)}  ${padLeft(c, 7)}`;
  const rows: Row[] = [{ spans: [{ text: line("AGENTS", "MODEL", "RUNS", "TOKENS", "COST"), dim: true, bold: true }] }];
  for (const u of subagents) {
    rows.push({ spans: [{ text: line(shorten(u.type, tw), modelLabel(u.model, u.effort, mw), String(u.agents), kTokens(u.tokens), fmtUsd(u.costUsd)) }] });
  }
  return rows;
}

/**
 * The worker table, costliest first: one row per worker with columns for task, project, stage,
 * model, how long open, last activity, context fill (bar), tokens and cost, then its subagent
 * sub-table. A narrow pane drops the least important columns. Rules separate workers.
 */
export function workerTableRows(workers: readonly Worker[], nowSeconds: number, width: number): Row[] {
  const nameOf = (w: Worker): string => (w.display === "" ? w.id : w.display);
  const longest = Math.max(4, ...workers.map((w) => nameOf(w).length));
  const projW = Math.max(7, Math.min(18, Math.max(...workers.map((w) => w.project.length))));
  const order: Col[] = [
    { key: "task", head: "TASK", width: Math.min(32, longest), prio: 1 },
    { key: "project", head: "PROJECT", width: projW, prio: 6 },
    { key: "stage", head: "STAGE", width: 16, prio: 3 },
    { key: "model", head: "MODEL", width: 19, prio: 5 },
    { key: "open", head: "OPEN", width: 7, prio: 4 },
    { key: "active", head: "ACTIVE", width: 8, prio: 7 },
    { key: "context", head: "CONTEXT", width: 16, prio: 2 },
    { key: "tokens", head: "TOKENS", width: 7, right: true, prio: 8 },
    { key: "cost", head: "COST", width: 7, right: true, prio: 1 },
  ];
  const { cols, inline } = withBreakdown(fitColumns(order, width), width, workers.map((w) => tokenParen(w.breakdown)));
  const rows: Row[] = [headerRow(cols)];
  const byCost = [...workers].sort((a, b) => (b.costUsd ?? -1) - (a.costUsd ?? -1) || a.id.localeCompare(b.id));
  for (const w of byCost) {
    const color = stateColor(w.state);
    const active = fmtAge(w.lastEventAt, nowSeconds);
    const dots = stageDots(w.stageStep, w.stageTotal);
    const high = w.contextPct !== null && w.contextPct >= 85;
    const ctx: Span[] =
      w.contextPct === null
        ? [{ text: "n/a", dim: true }]
        : [
            { text: gauge(w.contextPct, 6).on, color: high ? "error" : "claude" },
            { text: gauge(w.contextPct, 6).off, dim: true },
            { text: ` ${w.contextPct}%`, color: high ? "error" : undefined },
            ...(w.contextTokens === null ? [] : [{ text: ` ${kTokens(w.contextTokens)}`, dim: true } as Span]),
          ];
    rows.push(ruleRow(width));
    rows.push(
      ...wrappedRows(cols, {
        project: [{ text: w.project === "" ? "-" : shorten(w.project, projW) }],
        stage: [{ text: dots === "" ? "" : `${dots} `, color }, { text: shorten(stageWord(w.stageLabel, w.state), 11) }],
        model: [{ text: modelLabel(w.model, w.effort, 19), dim: true }],
        open: [{ text: fmtOpen(w.startedAt, nowSeconds) }],
        active: [{ text: active === "" ? "-" : `${active} ago` }],
        context: ctx,
        tokens: [{ text: w.tokensTotal === null ? "n/a" : kTokens(w.tokensTotal) }],
        cost: [{ text: w.costUsd === null ? "n/a" : `${w.costExact ? "" : "~"}${fmtUsd(w.costUsd)}`, bold: true }],
        breakdown: [{ text: tokenParen(w.breakdown), dim: true }],
      }, "task", nameOf(w), { bold: true, color: w.waitingOnCaptain ? "error" : undefined }, 3),
    );
    if (!inline) rows.push(...breakdownRows(w.breakdown));
    rows.push(...subagentRows(w.subagents, width));
  }
  rows.push(ruleRow(width));
  return rows;
}

/** The history rows whose task ended within the last `days` days, newest first, duplicates collapsed. */
export function filterHistory(rows: readonly HistoryRow[], nowSeconds: number, days: number): HistoryRow[] {
  const cutoff = nowSeconds - days * 86400;
  const seen = new Set<string>();
  const kept: HistoryRow[] = [];
  for (const row of [...rows].sort((a, b) => b.endedAt - a.endedAt)) {
    if (row.endedAt < cutoff || seen.has(row.task)) continue;
    seen.add(row.task);
    kept.push(row);
  }
  return kept;
}

/** `412k tok`, `1.2M tok`, or `-` when no spend was recorded; a `+` marks a lower bound. */
export function fmtSpend(tokens: number | null, unknown: number): string {
  if (tokens === null) return "-";
  return `${kTokens(tokens)}${unknown > 0 ? "+" : ""} tok`;
}

/** Most queue rows drawn at once; the rest are counted. */
export const QUEUE_MAX_ROWS = 14;

/** Whole days between an ISO date (`2026-10-26`) and now; null when it does not parse. */
const daysSince = (iso: string, nowSeconds: number): number | null => {
  const ms = Date.parse(`${iso}T00:00:00Z`);
  return Number.isFinite(ms) ? Math.max(0, Math.floor((nowSeconds - ms / 1000) / 86400)) : null;
};

/** How many ready (not blocked, not held) items the queue lists as "next up". */
export const QUEUE_NEXT_UP = 3;

/**
 * The queue section: what is held for the captain, what launches next, and what is coming
 * after another task. Items held for the captain come first, then the next few ready items in
 * queue order, then work blocked on another task (what it waits on is in the tree below). The
 * rest of the ready work is only counted, and anything that already has a live worker is left
 * out so nothing shows twice.
 */
export function queueRows(all: readonly QueueItem[], nowSeconds: number, width: number, liveIds: ReadonlySet<string> = new Set()): Row[] {
  const open = all.filter((q) => !liveIds.has(q.id));
  const heldItems = open.filter((q) => q.held);
  const readyItems = open.filter((q) => !q.held && q.blockedBy.length === 0);
  const nextUp = readyItems.slice(0, QUEUE_NEXT_UP);
  const afterItems = open.filter((q) => !q.held && q.blockedBy.length > 0);
  const restReady = readyItems.length - nextUp.length;
  const queue: { item: QueueItem; tag: "held" | "next" | "after" }[] = [
    ...heldItems.map((item) => ({ item, tag: "held" as const })),
    ...nextUp.map((item) => ({ item, tag: "next" as const })),
    ...afterItems.map((item) => ({ item, tag: "after" as const })),
  ];
  const rows: Row[] = [
    {
      spans: [
        { text: `QUEUE ${VIEW_NAME}`, bold: true },
        ...(heldItems.length > 0 ? [{ text: ` · ${heldItems.length} held for you`, color: "error", bold: true } as Span] : []),
        {
          text: `${nextUp.length > 0 ? ` · ${nextUp.length} next up` : ""}${afterItems.length > 0 ? ` · ${afterItems.length} coming after` : ""}${restReady > 0 ? ` · ${restReady} more ready (not listed)` : ""}`,
          dim: true,
        },
      ],
    },
  ];
  if (queue.length === 0) {
    rows.push({ spans: [{ text: "nothing held for you, nothing next", dim: true }] });
    return rows;
  }
  const cols = fitColumns(
    [
      { key: "title", head: "TASK", width: 64, prio: 1 },
      { key: "project", head: "PROJECT", width: 17, prio: 3 },
      { key: "kind", head: "KIND", width: 7, prio: 5 },
      { key: "age", head: "AGE", width: 5, prio: 4 },
      { key: "state", head: "STATE", width: 20, prio: 2 },
    ],
    width,
  );
  rows.push(headerRow(cols));
  for (const { item: q, tag } of queue) {
    const age = daysSince(q.since, nowSeconds);
    const state: Span =
      tag === "held"
        ? { text: "▲ held for you", color: "error", bold: true }
        : tag === "after"
          ? { text: `after: ${q.blockedBy[0]}${q.blockedBy.length > 1 ? ` +${q.blockedBy.length - 1}` : ""}`, dim: true }
          : { text: "next up" };
    rows.push(
      ...wrappedRows(cols, {
        project: [{ text: q.repo === "" ? "-" : shorten(q.repo, 17), dim: true }],
        kind: [{ text: q.kind === "" ? "-" : q.kind, dim: true }],
        age: [{ text: age === null ? "-" : `${age}d`, dim: true }],
        state: [{ ...state, text: shorten(state.text, 20) }],
      }, "title", q.title, { bold: tag === "held" }, 4),
    );
  }
  return rows;
}

/** What a node in the dependency tree is doing, from the backlog section it sits in. */
function nodeState(item: GraphItem | undefined): { glyph: string; word: string; color: string | undefined } {
  if (item === undefined) return { glyph: "✓", word: "finished", color: "success" };
  if (item.section === "Done") return { glyph: "✓", word: "done", color: "success" };
  if (item.section === "In flight") return { glyph: "●", word: "running", color: "claude" };
  if (item.held) return { glyph: "▲", word: "held for you", color: "error" };
  return { glyph: "○", word: "queued", color: undefined };
}

/**
 * The dependency tree, read top-down: a root is a task nothing unfinished is holding up, and
 * beneath it sit the tasks that wait on it. A solid branch (`├─`) is a hard dependency, a dotted
 * branch (`├┄`) is partial: related, but the two can run at the same time. A task that waits on
 * several others is drawn in full under the first and shown as a short `↳` reference under the
 * rest, and every task lists its other unfinished prerequisites on its own line. Finished
 * prerequisites are not drawn, only counted. Nothing is drawn when no task has a link.
 */
export function treeRows(graph: readonly GraphItem[], width: number): Row[] {
  const byId = new Map(graph.map((g) => [g.id, g]));
  const isLive = (g: GraphItem | undefined): g is GraphItem => g !== undefined && (g.section === "In flight" || g.section === "Queued");
  type Edge = { from: string; to: string; dotted: boolean };
  const edges: Edge[] = [];
  for (const g of graph) {
    if (!isLive(g)) continue;
    for (const id of g.blockedBy) edges.push({ from: id, to: g.id, dotted: false });
    for (const id of g.softAfter) if (!g.blockedBy.includes(id)) edges.push({ from: id, to: g.id, dotted: true });
  }
  // only edges whose prerequisite is still unfinished are drawn
  const open = edges.filter((e) => isLive(byId.get(e.from)));
  // a live task whose prerequisites all finished still shows, with its last finished ones noted
  const afterFinished = [...new Set(edges.filter((e) => !isLive(byId.get(e.from)) && isLive(byId.get(e.to))).map((e) => e.to))];
  if (open.length === 0 && afterFinished.length === 0) return [];
  const before = new Map<string, Edge[]>();
  const after = new Map<string, Edge[]>();
  for (const e of open) {
    before.set(e.to, [...(before.get(e.to) ?? []), e]);
    after.set(e.from, [...(after.get(e.from) ?? []), e]);
  }
  const finishedOf = (id: string): string[] =>
    edges.filter((e) => e.to === id && !isLive(byId.get(e.from))).map((e) => e.from);
  // Done entries are listed newest first, so a lower index is a more recent finish; unknown ids count as oldest
  const doneOrder = (id: string): number => {
    const i = graph.findIndex((g) => g.id === id && g.section === "Done");
    return i < 0 ? Number.MAX_SAFE_INTEGER : i;
  };
  const recentFinished = (id: string): string[] => [...finishedOf(id)].sort((x, y) => doneOrder(x) - doneOrder(y)).slice(0, 2);
  const rank = (id: string): string => `${byId.get(id)?.section === "In flight" ? "0" : "1"}${id}`;
  const roots = [...new Set([...after.keys(), ...afterFinished])]
    .filter((id) => !before.has(id))
    .sort((x, y) => rank(x).localeCompare(rank(y)));
  const rows: Row[] = [
    { spans: [{ text: `DEPENDENCIES ${VIEW_NAME}`, bold: true }, { text: "  top = held up by nothing, below = waits on it   ─ must finish first   ┄ related, can run at the same time", dim: true }] },
  ];
  const nodeSpans = (id: string, parent: string | null): Span[] => {
    const item = byId.get(id);
    const st = nodeState(item);
    const others = (before.get(id) ?? []).filter((e) => e.from !== parent);
    const spans: Span[] = [
      { text: `${st.glyph} `, color: st.color },
      { text: shorten(`${id}  ${item?.title ?? ""}`.trim(), Math.max(24, width - 60)) },
      { text: `  ${st.word}`, color: st.color, dim: st.color === undefined },
    ];
    const notes: string[] = [];
    if (others.length > 0) notes.push(`also ${others.map((e) => `${e.dotted ? "related to" : "needs"} ${e.from} ${nodeState(byId.get(e.from)).glyph}`).join(", ")}`);
    const done = finishedOf(id);
    const recent = recentFinished(id);
    if (done.length > 0) {
      const earlier = done.length - recent.length;
      notes.push(`after ✓ ${recent.join(", ")}${earlier > 0 ? ` +${earlier} earlier` : ""}`);
    }
    if (notes.length > 0) spans.push({ text: `   (${notes.join("; ")})`, dim: true });
    return spans;
  };
  const shown = new Set<string>();
  const draw = (id: string, indent: string, parent: string | null, out: Row[]): void => {
    shown.add(id);
    const kids = [...(after.get(id) ?? [])].sort((x, y) => rank(x.to).localeCompare(rank(y.to)));
    kids.forEach((e, i) => {
      const last = i === kids.length - 1;
      const branch = e.dotted ? (last ? "└┄ " : "├┄ ") : last ? "└─ " : "├─ ";
      const bar = e.dotted ? "┊  " : "│  ";
      const prefix = { text: `${indent}${branch}`, dim: true } as Span;
      const owner = (before.get(e.to) ?? [])[0]?.from;
      if (shown.has(e.to) || owner !== id) {
        // drawn in full under its first prerequisite; only a reference here
        out.push({ spans: [prefix, { text: `↳ ${e.to}`, dim: true }, { text: owner !== undefined && owner !== id ? `  (shown under ${owner})` : "  (shown above)", dim: true }] });
        return;
      }
      out.push({ spans: [prefix, ...nodeSpans(e.to, id)] });
      draw(e.to, `${indent}${last ? "   " : bar}`, id, out);
    });
  };
  for (const root of roots) {
    rows.push({ spans: [{ text: "" }] });
    rows.push({ spans: nodeSpans(root, null) });
    draw(root, "", null, rows);
  }
  return rows;
}

/** `#3361` from a Bitbucket or GitHub PR link (`.../pull-requests/3361`, `.../pull/7`); empty when it has none. */
export const prNumber = (url: string): string => {
  const m = /\/pull(?:-requests)?\/(\d+)/.exec(url);
  return m === null ? "" : `#${m[1]}`;
};

/**
 * What became of a finished task: `merged #3361` / `merged local`, `closed #3361` (declined), `PR #3361`
 * (cleaned up with a PR but no merge or decline on record), `report` (a scout), or `no PR` (cleaned up
 * with no PR and no merge on record: abandoned, or finished before the ledger captured PRs).
 */
export function outcomeLabel(row: HistoryRow): string {
  const n = prNumber(row.pr);
  if (row.outcome === "merged") return row.via === "local" ? "merged local" : n === "" ? "merged" : `merged ${n}`;
  if (row.outcome === "closed") return n === "" ? "closed" : `closed ${n}`;
  if (n !== "") return `PR ${n}`;
  return row.kind === "scout" ? "report" : "no PR";
}

/** The per-model spend of the given history rows and workers, costliest first, one entry per short model name. */
export function costByModel(sources: readonly { byModel: readonly ModelUse[] }[]): { name: string; costUsd: number; tokens: number }[] {
  const sums = new Map<string, { costUsd: number; tokens: number }>();
  for (const src of sources) {
    for (const u of src.byModel) {
      const name = shortModel(u.model);
      const cur = sums.get(name) ?? { costUsd: 0, tokens: 0 };
      sums.set(name, { costUsd: cur.costUsd + u.costUsd, tokens: cur.tokens + u.tokens });
    }
  }
  return [...sums.entries()].map(([name, v]) => ({ name, ...v })).sort((a, b) => b.costUsd - a.costUsd || a.name.localeCompare(b.name));
}

/** `opus 5.5 $14.20 52% · sonnet 5.5 $11.00 40%`: each model's spend and its share; empty when nothing is priced. */
export function modelShareText(sources: readonly { byModel: readonly ModelUse[] }[], maxModels = 4): string {
  const all = costByModel(sources);
  const total = all.reduce((n, m) => n + m.costUsd, 0);
  if (all.length === 0 || total <= 0) return "";
  const pct = (c: number): string => `${Math.round((c / total) * 100)}%`;
  const parts = all.slice(0, maxModels).map((m) => `${m.name} ${fmtUsd(m.costUsd)} ${pct(m.costUsd)}`);
  const rest = all.slice(maxModels);
  if (rest.length > 0) parts.push(`+${rest.length} other ${fmtUsd(rest.reduce((n, m) => n + m.costUsd, 0))}`);
  return parts.join(" · ");
}

/** Median of `values`; null when there are none. */
export const median = (values: readonly number[]): number | null => {
  if (values.length === 0) return null;
  const v = [...values].sort((a, b) => a - b);
  const mid = Math.floor(v.length / 2);
  return v.length % 2 === 1 ? (v[mid] as number) : ((v[mid - 1] as number) + (v[mid] as number)) / 2;
};

/**
 * One line summing up the finished tasks of a window: how many merged, the spend of all of them, the
 * cost per merged task, and the median time to merge. Empty when no task finished.
 */
export function windowSummary(rows: readonly HistoryRow[]): string {
  if (rows.length === 0) return "";
  const merged = rows.filter((r) => r.outcome === "merged");
  const spend = rows.reduce((n, r) => n + (r.costUsd ?? 0), 0);
  const parts = [`${rows.length} finished`, `${merged.length} merged`, `spend ${fmtUsd(spend)}`];
  const priced = merged.filter((r) => r.costUsd !== null);
  if (priced.length > 0) parts.push(`${fmtUsd(priced.reduce((n, r) => n + (r.costUsd ?? 0), 0) / priced.length)}/merged`);
  const med = median(merged.flatMap((r) => (r.durationS === null ? [] : [r.durationS])));
  if (med !== null) parts.push(`median ${fmtDuration(med * 1000)}`);
  return parts.join(" · ");
}

/**
 * The history columns that fit `width`, in display order, with the token-breakdown column when
 * the longest of `parens` fits too.
 */
function historyColumns(width: number, parens: readonly string[] = []): { cols: Col[]; inline: boolean } {
  return withBreakdown(fitColumns(
    [
      { key: "task", head: "TASK", width: 26, prio: 1 },
      { key: "outcome", head: "OUTCOME", width: 14, prio: 2 },
      { key: "project", head: "PROJECT", width: 17, prio: 3 },
      { key: "model", head: "MODEL", width: 19, prio: 5 },
      { key: "ended", head: "ENDED", width: 9, prio: 4 },
      { key: "ran", head: "RAN", width: 8, prio: 6 },
      { key: "pipe", head: "PIPE", width: 7, right: true, prio: 7 },
      { key: "tokens", head: "TOKENS", width: 7, right: true, prio: 5 },
      { key: "cost", head: "COST", width: 7, right: true, prio: 1 },
    ],
    width,
  ), width, parens);
}

/**
 * One table row per finished task, then its subagent sub-table when it used any. `parens` are the
 * breakdowns of every row drawn in the same table, so they all share one column width.
 */
export function historyRow(row: HistoryRow, nowSeconds: number, width: number, parens: readonly string[] = [tokenParen(row.breakdown, true)]): Row[] {
  const { cols, inline } = historyColumns(width, parens);
  const merged = row.outcome === "merged";
  const taskW = cols.find((c) => c.key === "task")?.width ?? 12;
  const rows: Row[] = [
    tableRow(cols, {
      task: [{ text: shorten(row.task, taskW), color: merged ? "success" : undefined }],
      outcome: [{ text: shorten(outcomeLabel(row), 14), color: merged ? "success" : row.outcome === "closed" ? "error" : undefined, dim: !merged && row.outcome !== "closed" }],
      project: [{ text: row.project === "" ? "-" : shorten(row.project, 17), dim: true }],
      model: [{ text: row.model === "" ? "-" : modelLabel(row.model, row.effort, 19), dim: true }],
      ended: [{ text: `${fmtAge(row.endedAt, nowSeconds)} ago`, dim: true }],
      ran: [{ text: row.durationS === null ? "-" : fmtDuration(row.durationS * 1000), dim: true }],
      pipe: [{ text: row.spendTokens === null ? "-" : `${kTokens(row.spendTokens)}${row.spendUnknown > 0 ? "+" : ""}`, dim: true }],
      tokens: [{ text: row.tokens === null ? "-" : kTokens(row.tokens) }],
      cost: [{ text: row.costUsd === null ? "-" : `${row.costExact ? "" : "~"}${fmtUsd(row.costUsd)}`, bold: true }],
      breakdown: [{ text: tokenParen(row.breakdown, true), dim: true }],
    }),
  ];
  if (!inline) rows.push(...breakdownRows(row.breakdown));
  if (row.subagents.length > 0) rows.push(...subagentRows(row.subagents, width));
  return rows;
}

/**
 * The history section: a heading naming the window and how to switch it, a table header, then
 * one row per task finished inside the window, or an empty-state line. The ledgers only record
 * from when they were enabled, so the empty state says so and names that date when it is known.
 */
export function historyRows(history: History, nowSeconds: number, width: number, days: number, live: readonly Worker[] = []): Row[] {
  const other = nextHistoryWindow(days);
  const rows: Row[] = [
    { spans: [{ text: `HISTORY ${VIEW_NAME}`, bold: true }, { text: ` · last ${days}d · ${VIEW_NAME} history ${other} for ${other}d`, dim: true }] },
  ];
  const kept = filterHistory(history.rows, nowSeconds, days);
  if (kept.length === 0) {
    const since =
      history.ledgerSince === null ? "no ledger yet" : `ledger records since ${new Date(history.ledgerSince * 1000).toISOString().slice(0, 10)}`;
    rows.push({ spans: [{ text: `no finished tasks in the last ${days}d (${since})`, dim: true }] });
    return rows;
  }
  const summary = windowSummary(kept);
  if (summary !== "") rows.push({ spans: [{ text: shorten(`last ${days}d: ${summary}`, Math.max(20, width)), dim: true }] });
  const shares = modelShareText([...kept, ...live]);
  if (shares !== "") rows.push({ spans: [{ text: shorten(`spend by model (history + live): ${shares}`, Math.max(20, width)), dim: true }] });
  const shown = kept.slice(0, HISTORY_MAX_ROWS);
  const parens = shown.map((r) => tokenParen(r.breakdown, true));
  // Subagent sub-tables break the column layout, so tasks are then ruled apart like the worker table.
  const ruled = shown.some((r) => r.subagents.length > 0);
  rows.push(headerRow(historyColumns(width, parens).cols));
  for (const row of shown) {
    rows.push(ruled ? ruleRow(width) : { spans: [{ text: "" }] });
    rows.push(...historyRow(row, nowSeconds, width, parens));
  }
  if (ruled) rows.push(ruleRow(width));
  if (kept.length > HISTORY_MAX_ROWS) {
    rows.push({ spans: [{ text: `+${kept.length - HISTORY_MAX_ROWS} more`, dim: true }] });
  }
  return rows;
}

/** Every row of the pane in order: header, the worker table, then the history table. */
export function paneRows(pulse: Pulse | undefined, nowSeconds: number, width: number, historyDays: number = HISTORY_DEFAULT_DAYS): Row[] {
  if (pulse === undefined) {
    return [
      { spans: [{ text: `FLEET ${VIEW_NAME}`, bold: true }] },
      { spans: [{ text: "no pulse yet: run bin/fm-fleet-pulse-ensure.sh", dim: true }] },
    ];
  }
  const rows: Row[] = headerRows(pulse, nowSeconds);
  const staleFor = nowSeconds - pulse.generatedAt;
  if (pulse.generatedAt > 0 && staleFor > 480) {
    rows.push({ spans: [{ text: `pulse is ${fmtAge(pulse.generatedAt, nowSeconds)} old: is the sidecar running?`, color: "warning" }] });
  }
  if (pulse.workers.length === 0) rows.push({ spans: [{ text: "no workers", dim: true }] });
  rows.push(...sectionBreak(width));
  if (pulse.workers.length > 0) {
    rows.push({ spans: [{ text: "" }] });
    rows.push(...workerTableRows(pulse.workers, nowSeconds, width));
  }
  rows.push(...sectionBreak(width));
  rows.push(...queueRows(pulse.queue, nowSeconds, width, new Set(pulse.workers.map((w) => w.id))));
  const tree = treeRows(pulse.graph, width);
  if (tree.length > 0) {
    rows.push(...sectionBreak(width));
    rows.push(...tree);
  }
  rows.push(...sectionBreak(width));
  rows.push(...historyRows(pulse.history, nowSeconds, width, historyDays, pulse.workers));
  return rows;
}

/** The plain text of rows, one line per row, for logs and the README sample. */
export const rowsToText = (rows: readonly Row[]): string =>
  rows.map((row) => row.spans.map((s) => s.text).join("")).join("\n");

type StateEnvironment = { FM_HOME?: string; FM_ROOT_OVERRIDE?: string; FM_STATE_OVERRIDE?: string };

/**
 * The home's state directory, resolved as the Calm mod and the Pi extension resolve it:
 * `FM_STATE_OVERRIDE`, else `<FM_HOME | FM_ROOT_OVERRIDE | code root>/state`. The code root
 * is three directories above the plugin root (`<root>/.claude/mods/firstmate-fleet`).
 */
export function fleetStateDirectory(env: StateEnvironment, pluginRoot: string): string {
  const parent = (path: string): string => path.replace(/\/+$/, "").replace(/\/[^/]*$/, "");
  return env.FM_STATE_OVERRIDE || `${env.FM_HOME || env.FM_ROOT_OVERRIDE || parent(parent(parent(pluginRoot)))}/state`;
}
