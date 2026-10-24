/** Mirrors the daemon's full replacement snapshots. No client infers attention
 * from terminal text or treats acknowledgement as provider approval. */
export interface AttentionItem {
  id: string;
  sessionId: string;
  kind: string;
  createdAt: number;
  updatedAt: number;
  acknowledged: boolean;
  resolved: boolean;
  source?: "program";
}
export interface AttentionResult {
  ok: boolean;
  error?: string;
}
export function parseAttention(raw: unknown): AttentionItem[] | null {
  if (!Array.isArray(raw)) return null;
  const items: AttentionItem[] = [];
  for (const value of raw) {
    if (!value || typeof value !== "object") return null;
    const row = value as Record<string, unknown>;
    if (
      typeof row.id !== "string" ||
      !row.id ||
      typeof row.sessionId !== "string" ||
      !row.sessionId ||
      typeof row.kind !== "string" ||
      typeof row.createdAt !== "number" ||
      !Number.isFinite(row.createdAt) ||
      typeof row.updatedAt !== "number" ||
      !Number.isFinite(row.updatedAt) ||
      typeof row.acknowledged !== "boolean" ||
      typeof row.resolved !== "boolean"
    )
      return null;
    items.push({
      id: row.id,
      sessionId: row.sessionId,
      kind: row.kind,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      acknowledged: row.acknowledged,
      resolved: row.resolved,
      ...(row.source === "program" ? { source: "program" as const } : {}),
    });
  }
  return items;
}
export function actionableAttention(items: readonly AttentionItem[]): AttentionItem[] {
  return items
    .filter((i) => !i.resolved && (i.kind === "waiting" || !i.acknowledged))
    .sort((a, b) => a.createdAt - b.createdAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

export class AttentionMirror {
  items: AttentionItem[] | null = null;
  supported = false;
  private nextRequest = 0;
  private listeners = new Set<(items: AttentionItem[] | null) => void>();
  private pending = new Map<string, (result: AttentionResult) => void>();
  constructor(private send: (frame: Record<string, unknown>) => void) {}
  subscribe(listener: (items: AttentionItem[] | null) => void): () => void {
    this.listeners.add(listener);
    listener(this.items);
    return () => {
      this.listeners.delete(listener);
    };
  }
  private publish(items: AttentionItem[] | null): void {
    this.items = items;
    for (const listener of this.listeners) {
      try {
        listener(items);
      } catch (error) {
        console.warn("attention listener failed:", error);
      }
    }
  }
  reset(): void {
    this.supported = false;
    this.publish(null);
    for (const settle of this.pending.values())
      settle({ ok: false, error: "attention-connection-lost" });
    this.pending.clear();
  }
  handle(frame: Record<string, unknown>): void {
    if (frame.type === "serverInfo") {
      this.reset();
      this.supported =
        Array.isArray(frame.capabilities) && frame.capabilities.includes("attention");
      if (this.supported) this.send({ type: "subscribeAttention" });
    } else if (frame.type === "attention" && this.supported) {
      const items = parseAttention(frame.items);
      if (items) this.publish(items);
    } else if (frame.type === "attentionResult") {
      if (typeof frame.requestId !== "string") {
        this.publish(null);
        return;
      }
      const settle = this.pending.get(frame.requestId);
      this.pending.delete(frame.requestId);
      settle?.(
        frame.ok === true
          ? { ok: true }
          : {
              ok: false,
              error: typeof frame.error === "string" ? frame.error : "attention-failed",
            },
      );
    }
  }
  acknowledge(id: string): Promise<AttentionResult> {
    if (!this.supported || this.items === null)
      return Promise.resolve({ ok: false, error: "attention-unavailable" });
    const requestId = `attention-${++this.nextRequest}`;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId);
        resolve({ ok: false, error: "attention-timeout" });
      }, 10_000);
      this.pending.set(requestId, (result) => {
        clearTimeout(timer);
        resolve(result);
      });
      this.send({ type: "acknowledgeAttention", id, requestId });
    });
  }
}
