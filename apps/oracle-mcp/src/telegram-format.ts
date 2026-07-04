// Pure parsing/formatting helpers for the Telegram session control surface
// (juancode-2l4). No I/O here — everything is unit-testable data-in/data-out:
// parse the native /api/sessions payload, order + render session lists, classify
// activity events into notification-worthy kinds, and resolve the user's
// "/observe 2"-style selectors.

/** The slice of the native server's SessionMeta the Telegram surface needs. */
export interface SessionSummary {
  id: string;
  provider: string;
  cwd: string;
  title: string;
  status: string; // "running" | "exited"
  archived: boolean;
  updatedAt: number;
}

/** Live activity as broadcast on the native WS (`activity` messages). */
export type LiveActivity = "busy" | "idle" | "waiting_input";

/** A state transition worth telling an observer about. `needs_input` and
 *  `finished` come from the server's de-spammed `notify` flag on activity
 *  transitions; process exit isn't passively observable from the native WS. */
export type NotifyKind = "needs_input" | "finished";

/** Parse the untyped /api/sessions payload into summaries, dropping malformed rows. */
export function parseSessionList(raw: unknown): SessionSummary[] {
  const list = Array.isArray(raw)
    ? raw
    : ((raw as { sessions?: unknown[] })?.sessions ?? []);
  if (!Array.isArray(list)) return [];
  const out: SessionSummary[] = [];
  for (const item of list) {
    if (!item || typeof item !== "object") continue;
    const r = item as Record<string, unknown>;
    if (typeof r.id !== "string" || !r.id) continue;
    out.push({
      id: r.id,
      provider: typeof r.provider === "string" ? r.provider : "?",
      cwd: typeof r.cwd === "string" ? r.cwd : "",
      title: typeof r.title === "string" && r.title.trim() ? r.title.trim() : r.id.slice(0, 8),
      status: typeof r.status === "string" ? r.status : "unknown",
      archived: r.archived === true,
      updatedAt: typeof r.updatedAt === "number" ? r.updatedAt : 0,
    });
  }
  return out;
}

/** Display order: non-archived only, running before exited, most recent first. */
export function orderSessions(list: SessionSummary[]): SessionSummary[] {
  return list
    .filter((s) => !s.archived)
    .sort((a, b) => {
      const aRun = a.status === "running" ? 0 : 1;
      const bRun = b.status === "running" ? 0 : 1;
      return aRun !== bRun ? aRun - bRun : b.updatedAt - a.updatedAt;
    });
}

/** Last path segment of the session's cwd — the human "project" name. */
export function projectName(cwd: string): string {
  const seg = cwd.replace(/\/+$/, "").split("/").pop();
  return seg || cwd || "?";
}

/** One-glyph state indicator: live activity wins over the persisted status. */
export function stateIcon(status: string, activity: LiveActivity | undefined): string {
  if (status === "exited") return "⚫";
  switch (activity) {
    case "busy":
      return "🔵";
    case "waiting_input":
      return "🟡";
    case "idle":
      return "🟢";
    default:
      return status === "running" ? "⚪" : "⚫";
  }
}

/** Human state label matching {@link stateIcon}. */
export function stateLabel(status: string, activity: LiveActivity | undefined): string {
  if (status === "exited") return "exited";
  switch (activity) {
    case "busy":
      return "working";
    case "waiting_input":
      return "waiting for input";
    case "idle":
      return "idle";
    default:
      return status === "running" ? "running" : status;
  }
}

/** One numbered session line for /sessions and /status. */
export function formatSessionLine(
  index: number,
  s: SessionSummary,
  activity: LiveActivity | undefined,
  observed: boolean,
): string {
  const eye = observed ? " 👁" : "";
  return (
    `${index}. ${stateIcon(s.status, activity)} ${s.title}${eye}\n` +
    `    ${projectName(s.cwd)} · ${s.provider} · ${stateLabel(s.status, activity)}`
  );
}

/** Classify an activity broadcast into a notification kind, or null when it isn't
 *  alert-worthy. Leans entirely on the server's notificationGate: only transitions
 *  it flagged `notify` can alert, so Telegram inherits the existing de-spam. */
export function classifyActivity(state: LiveActivity, notify: boolean): NotifyKind | null {
  if (!notify) return null;
  if (state === "waiting_input") return "needs_input";
  if (state === "idle") return "finished";
  return null;
}

export function notifyIcon(kind: NotifyKind): string {
  return kind === "needs_input" ? "🟡" : "✅";
}

export function notifyText(kind: NotifyKind): string {
  return kind === "needs_input" ? "needs your input" : "finished its turn";
}

/**
 * Resolve a user-typed session selector: a 1-based index into the last list the
 * bot printed for this chat (falling back to the freshly ordered list), or an id /
 * unique id-prefix. Returns the session id, or null when nothing (or more than
 * one thing) matches.
 */
export function resolveSelector(
  selector: string,
  ordered: SessionSummary[],
  lastList: string[] | undefined,
): string | null {
  const sel = selector.trim();
  if (!sel) return null;
  if (/^\d+$/.test(sel)) {
    const n = Number(sel);
    const ids = lastList && lastList.length > 0 ? lastList : ordered.map((s) => s.id);
    return n >= 1 && n <= ids.length ? ids[n - 1]! : null;
  }
  const exact = ordered.find((s) => s.id === sel);
  if (exact) return exact.id;
  const prefixed = ordered.filter((s) => s.id.startsWith(sel));
  return prefixed.length === 1 ? prefixed[0]!.id : null;
}
