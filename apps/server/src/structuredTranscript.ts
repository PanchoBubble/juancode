import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import {
  CLAUDE_PROJECTS,
  CODEX_SESSIONS,
  codexRolloutFiles,
  findByBasename,
  forEachRecord,
} from "./sessionTitle.ts";
import { recordToEvents } from "./structuredEvents.ts";
import type { ProviderId, StructuredEvent } from "./protocol.ts";

/**
 * Tails a session's stream-json transcript and emits normalized
 * {@link StructuredEvent}s — first the full backlog (`reset: true`), then each
 * newly appended batch (`reset: false`) as the live CLI writes more turns.
 *
 * Transcripts only ever grow, so tailing is a byte-offset read: each poll reads
 * the slice from the last offset to EOF, parses the complete lines it finds (a
 * trailing partial line is buffered for the next poll), and feeds each record
 * through {@link recordToEvents}. A per-record `seq` counter makes every event's
 * id stable across polls so the client can dedup. Works for exited sessions too
 * — the backlog is read once and later polls simply find nothing new.
 */

/** Override the transcript roots (used by tests to point at fixtures). */
export interface TranscriptRoots {
  claudeProjects?: string;
  codexSessions?: string;
}

/** Locate a session's transcript file from its CLI session id, or null if not found yet. */
export async function resolveTranscriptFile(
  provider: ProviderId,
  cliSessionId: string,
  roots: TranscriptRoots = {},
): Promise<string | null> {
  if (provider === "claude") {
    return findByBasename(roots.claudeProjects ?? CLAUDE_PROJECTS, `${cliSessionId}.jsonl`);
  }
  // Codex files aren't named by session id, so match the `session_meta` header.
  for (const file of await codexRolloutFiles(roots.codexSessions ?? CODEX_SESSIONS)) {
    let match = false;
    await forEachRecord(file, (rec) => {
      if (rec.type === "session_meta") {
        const payload = rec.payload as { id?: string } | undefined;
        match = payload?.id === cliSessionId;
      }
      return false; // the header is the first record — only ever check it
    });
    if (match) return file;
  }
  return null;
}

export type StructuredListener = (events: StructuredEvent[], reset: boolean) => void;

const DEFAULT_POLL_MS = 1000;

export class TranscriptTail {
  private file: string | null = null;
  private offset = 0;
  private seq = 0;
  /** Carries an incomplete trailing line between polls. */
  private partial = "";
  private sentBacklog = false;
  private timer: NodeJS.Timeout | null = null;
  private polling = false;

  /**
   * `cliSessionId` may be a getter rather than a value: Codex discovers its id
   * shortly after spawn, so the tail re-reads it each poll until one appears.
   */
  constructor(
    private readonly provider: ProviderId,
    private readonly cliSessionId: string | null | (() => string | null),
    private readonly listener: StructuredListener,
    private readonly roots: TranscriptRoots = {},
  ) {}

  /** Poll once immediately, then on an interval until {@link stop}. */
  start(intervalMs: number = DEFAULT_POLL_MS): void {
    if (this.timer) return;
    void this.poll();
    this.timer = setInterval(() => void this.poll(), intervalMs);
  }

  stop(): void {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }

  /**
   * Read any new transcript bytes and emit their events. The first emission is
   * the full backlog with `reset: true` (even when empty, so the client clears
   * its view); later emissions carry only the appended events.
   */
  async poll(): Promise<void> {
    if (this.polling) return; // a slow read shouldn't overlap the next tick
    this.polling = true;
    try {
      if (!this.file) {
        const id =
          typeof this.cliSessionId === "function" ? this.cliSessionId() : this.cliSessionId;
        if (!id) return; // id not captured yet (Codex) — retry next tick
        this.file = await resolveTranscriptFile(this.provider, id, this.roots);
        if (!this.file) return; // transcript not written yet — retry next tick
      }

      let size: number;
      try {
        ({ size } = await stat(this.file));
      } catch {
        return; // file vanished — leave the view as-is
      }
      if (size < this.offset) {
        // Shouldn't happen for an append-only transcript, but recover if it does.
        this.offset = 0;
        this.partial = "";
        this.seq = 0;
      }

      const events: StructuredEvent[] = [];
      if (size > this.offset) {
        const chunk = await this.readSlice(this.file, this.offset, size);
        this.offset = size;
        this.partial += chunk;
        const lines = this.partial.split("\n");
        this.partial = lines.pop() ?? ""; // keep the trailing partial line
        for (const line of lines) {
          if (!line.trim()) continue;
          let rec: Record<string, unknown>;
          try {
            rec = JSON.parse(line) as Record<string, unknown>;
          } catch {
            this.seq++; // keep ids stable even past an unparseable line
            continue;
          }
          events.push(...recordToEvents(this.provider, rec, this.seq++));
        }
      }

      if (!this.sentBacklog) {
        this.sentBacklog = true;
        this.listener(events, true);
      } else if (events.length > 0) {
        this.listener(events, false);
      }
    } finally {
      this.polling = false;
    }
  }

  private async readSlice(file: string, start: number, end: number): Promise<string> {
    const stream = createReadStream(file, { encoding: "utf8", start, end: end - 1 });
    let data = "";
    try {
      for await (const chunk of stream) data += chunk;
    } finally {
      stream.destroy();
    }
    return data;
  }
}
