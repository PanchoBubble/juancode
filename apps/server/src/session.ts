import { randomUUID } from "node:crypto";
import { basename } from "node:path";
import * as pty from "node-pty";
import { SCROLLBACK_LIMIT } from "./config.ts";
import { Scrollback } from "./scrollback.ts";
import { captureCodexSessionId } from "./codexSession.ts";
import { sessionDb } from "./db.ts";
import { PROVIDERS } from "./providers.ts";
import type { SpawnOptions } from "./providers.ts";
import { deriveSessionTitle } from "./sessionTitle.ts";
import { deriveSessionUsage } from "./sessionUsage.ts";
import { ActivityDetector } from "./activityDetector.ts";
import { notificationGate } from "./notificationGate.ts";
import { TranscriptTail } from "./structuredTranscript.ts";
import { promptSignature, regionContains } from "./initialPromptDelivery.ts";
import type { ProviderId, ScreenRow, SessionActivity, SessionMeta, SessionPrompt } from "./protocol.ts";

type OutputListener = (data: string) => void;
type ExitListener = (exitCode: number | null) => void;
type ActivityListener = (state: SessionActivity, notify: boolean) => void;
/** A coalesced frame of the live screen stream — see {@link Session.onScreen}. */
type ScreenListener = (rows: ScreenRow[], height: number, reset: boolean) => void;

/**
 * The result of seeding a fresh session with an initial prompt
 * ({@link Session.autoSubmit}). `ok: false` carries a reason so the caller can
 * surface it instead of leaving the session silently idle with an unsent prompt.
 */
export type AutoSubmitOutcome = { ok: true } | { ok: false; reason: string };

const PERSIST_DEBOUNCE_MS = 2000;
const TITLE_POLL_MS = 4000;
/**
 * Coalesce window for the live screen stream: many pty writes land per turn, but
 * a phone only needs a few frames a second. We diff the rendered screen at most
 * this often and push just the rows that changed — cheap on the wire, smooth on
 * the device.
 */
const SCREEN_FLUSH_MS = 80;

/** Tunables for the verified initial-prompt delivery in {@link Session.autoSubmit}. */
const SEED = {
  /** Cap on waiting for the TUI to settle (MCP load can be slow); paste anyway after. */
  readyMaxMs: 45_000,
  readyPollMs: 200,
  /** Per-attempt budget to confirm the paste landed in the input box. */
  landMs: 2_000,
  /** Per-attempt budget to confirm the Enter submitted. */
  submitMs: 4_000,
  pollMs: 150,
  maxAttempts: 3,
  /** Rows of the bottom screen region treated as the input-box area. */
  inputRows: 16,
} as const;

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

export class Session {
  readonly meta: SessionMeta;
  private readonly proc: pty.IPty;
  private readonly scrollback: Scrollback;
  private readonly outputListeners = new Set<OutputListener>();
  private readonly exitListeners = new Set<ExitListener>();
  private readonly activityListeners = new Set<ActivityListener>();
  private readonly screenListeners = new Set<ScreenListener>();
  /** Last screen frame we diffed against, so flushes only carry changed rows. */
  private lastScreenRows: string[] = [];
  private screenTimer: NodeJS.Timeout | null = null;
  private readonly detector: ActivityDetector;
  /**
   * Tails this session's stream-json transcript purely to feed structured
   * activity pulses into {@link detector} (the preferred, wording-independent
   * busy/idle signal). Independent of the client-facing structured *view* tail
   * in `ws.ts`, which is per-subscriber and may not exist. Started once spawned.
   */
  private readonly activityTail: TranscriptTail;
  private persistTimer: NodeJS.Timeout | null = null;
  private titleTimer: NodeJS.Timeout | null = null;

  private constructor(
    meta: SessionMeta,
    args: string[],
    cols: number,
    rows: number,
    isNew: boolean,
    seedScrollback = "",
  ) {
    this.meta = meta;
    this.detector = new ActivityDetector(cols, rows, (state, notify) => {
      // De-spam the alert flag: a live agent oscillates waiting_input↔busy and
      // ends many short turns, each a genuine transition. The gate collapses
      // those bursts so clients ding / OS-notify once, not once per repaint.
      const alert = notify && notificationGate.shouldNotify(this.meta.id, state);
      for (const l of this.activityListeners) l(state, alert);
    });
    // Preferred activity signal: pulse the detector busy on each batch of agent
    // records the CLI appends to its transcript. The id is read via a getter so
    // Codex (which discovers its id after spawn) starts tailing once it lands.
    this.activityTail = new TranscriptTail(
      meta.provider,
      () => this.meta.cliSessionId,
      (events, reset) => {
        // Skip the initial backlog: on a resumed session it replays the prior
        // conversation's agent records, which would spuriously pulse busy (and
        // then a phantom "turn finished" notification) at startup. Only newly
        // appended records reflect the live turn.
        if (!reset) this.detector.feedStructured(events);
      },
    );
    // Resuming an exited session carries its prior scrollback forward so the
    // history survives the new pty (and isn't clobbered by the persist below).
    this.scrollback = new Scrollback(SCROLLBACK_LIMIT, seedScrollback);
    const spec = PROVIDERS[meta.provider];

    this.proc = pty.spawn(spec.command, args, {
      name: "xterm-256color",
      cols,
      rows,
      cwd: meta.cwd,
      // Inherit the real environment so the CLI loads the user's auth + MCPs.
      env: process.env as Record<string, string>,
    });

    if (isNew) sessionDb.insert(this.meta);
    else sessionDb.update(this.meta, this.scrollback.replay);

    // For Codex we can't pin the session id, so discover it from the rollout file.
    if (!spec.pinsSessionId && this.meta.cliSessionId === null) {
      this.captureCliSessionId();
    }

    this.proc.onData((data) => {
      this.appendScrollback(data);
      this.detector.feed(data);
      for (const l of this.outputListeners) l(data);
      this.scheduleScreenFlush();
      this.schedulePersist();
    });

    this.proc.onExit(({ exitCode }) => {
      this.meta.status = "exited";
      this.meta.exitCode = exitCode;
      this.meta.updatedAt = Date.now();
      this.flushScreen(); // push the final frame before the screen goes static
      this.detector.reset();
      notificationGate.forget(this.meta.id);
      this.activityTail.stop();
      this.stopTitleWatch();
      void this.refreshTitle(); // one last read to catch a late-generated title
      void this.refreshUsage(); // and the final turn's token usage
      this.persistNow();
      for (const l of this.exitListeners) l(exitCode);
    });

    // Keep the title in sync with the CLI's own generated summary / first prompt.
    this.startTitleWatch();
    // Tail the transcript for structured activity pulses (see activityTail).
    this.activityTail.start();
  }

  /** Start a brand-new conversation. */
  static create(
    provider: ProviderId,
    cwd: string,
    cols: number,
    rows: number,
    opts?: SpawnOptions,
    worktreePath: string | null = null,
  ): Session {
    const spec = PROVIDERS[provider];
    const now = Date.now();
    const id = randomUUID();
    const meta: SessionMeta = {
      id,
      provider,
      cwd,
      title: `${spec.label} · ${basename(cwd) || cwd}`,
      status: "running",
      exitCode: null,
      // Claude's id is pinned to ours up front; Codex's is discovered post-spawn.
      cliSessionId: spec.pinsSessionId ? id : null,
      skipPermissions: opts?.skipPermissions ?? false,
      worktreePath,
      usage: null,
      createdAt: now,
      updatedAt: now,
    };
    return new Session(meta, spec.startArgs(id, opts), cols, rows, true);
  }

  /**
   * Revive an exited session by resuming its prior CLI conversation in a fresh
   * pty, keeping the same juancode id (so the route/sidebar entry is stable).
   * Requires a captured `cliSessionId`. `priorScrollback` is the persisted
   * history to carry forward so reactivation never loses the conversation.
   */
  static resume(prev: SessionMeta, cols: number, rows: number, priorScrollback = ""): Session {
    if (!prev.cliSessionId) {
      throw new Error("Session has no captured CLI session id to resume");
    }
    const spec = PROVIDERS[prev.provider];
    const meta: SessionMeta = {
      ...prev,
      status: "running",
      exitCode: null,
      updatedAt: Date.now(),
    };
    return new Session(
      meta,
      spec.resumeArgs(prev.cliSessionId, { skipPermissions: meta.skipPermissions }),
      cols,
      rows,
      false,
      priorScrollback,
    );
  }

  get id(): string {
    return this.meta.id;
  }

  get isRunning(): boolean {
    return this.meta.status === "running";
  }

  getScrollback(): string {
    return this.scrollback.replay;
  }

  write(data: string): void {
    if (this.isRunning) this.proc.write(data);
  }

  /**
   * Seed a fresh session with an initial prompt and **verify** it was actually
   * delivered, retrying on failure and reporting the outcome via `onResult` instead
   * of leaving the session silently idle with an unsent prompt.
   *
   * The old approach fired on the *first* output byte then pasted blind after a
   * fixed delay — but the first byte is the startup banner / MCP-loading chatter,
   * emitted seconds before the input box is in raw mode, so the paste could land
   * nowhere and the prompt would just rot in the box. Instead we:
   *   1. wait for the screen to *settle* (stable frames) so the input box is up,
   *   2. paste (bracketed `ESC[200~ … ESC[201~`) and confirm a signature of the
   *      prompt appears in the input-box region, re-pasting if it didn't,
   *   3. send a lone Enter and confirm submission — the agent goes busy or the
   *      prompt leaves the box — re-sending Enter if it didn't.
   * The bracketed-paste-then-separate-Enter split is still essential: a `${text}\r`
   * burst makes the CLI read the chunk as a paste and keep the CR as a literal
   * newline, leaving the prompt unsent.
   */
  autoSubmit(text: string, onResult?: (outcome: AutoSubmitOutcome) => void): void {
    const trimmed = text.trim();
    if (!trimmed) {
      onResult?.({ ok: true });
      return;
    }
    void this.deliverSeed(trimmed).then((outcome) => onResult?.(outcome));
  }

  /** The verified delivery state machine for {@link autoSubmit}. */
  private async deliverSeed(trimmed: string): Promise<AutoSubmitOutcome> {
    const signature = promptSignature(trimmed);

    // 1) Wait for the TUI to settle so the input box exists before we paste.
    await this.waitForStableScreen(SEED.readyMaxMs, SEED.readyPollMs);
    if (!this.isRunning) return { ok: false, reason: "session exited during startup" };

    // 2) Paste, then confirm the prompt actually landed in the input box.
    let landed = false;
    for (let i = 0; i < SEED.maxAttempts; i++) {
      if (!this.isRunning) return { ok: false, reason: "session exited before the prompt was typed" };
      if (this.isBusy()) return { ok: true }; // already working
      this.write(`\x1b[200~${trimmed}\x1b[201~`);
      landed = await this.waitUntil(
        SEED.landMs,
        SEED.pollMs,
        () => this.isBusy() || this.inputBoxContains(signature),
      );
      if (this.isBusy()) return { ok: true };
      if (landed) break;
    }
    if (!landed) {
      return { ok: false, reason: `the prompt never appeared in the input box after ${SEED.maxAttempts} tries` };
    }

    // 3) Submit, then confirm it went through (agent busy, or the box cleared).
    for (let i = 0; i < SEED.maxAttempts; i++) {
      if (!this.isRunning) return { ok: false, reason: "session exited before the prompt was submitted" };
      this.write("\r");
      const submitted = await this.waitUntil(
        SEED.submitMs,
        SEED.pollMs,
        () => this.isBusy() || !this.inputBoxContains(signature),
      );
      if (submitted) return { ok: true };
    }
    return { ok: false, reason: "the prompt stayed in the input box; it was never submitted" };
  }

  /**
   * Whether the agent is currently working. A method (not a bare `activity ===
   * "busy"`) so repeated checks across `await`s aren't narrowed away by TS.
   */
  private isBusy(): boolean {
    return this.activity === "busy";
  }

  /** True if the prompt `signature` is currently visible in the input-box region. */
  private inputBoxContains(signature: string): boolean {
    if (!signature) return true; // nothing distinctive to verify
    return regionContains(this.detector.inputRegionSnapshot(SEED.inputRows), signature);
  }

  /**
   * Resolve once the rendered screen stops changing (two identical, non-empty
   * frames `pollMs` apart) or `maxMs` elapses — a CLI-agnostic "TUI is ready"
   * signal that replaces trusting the first output byte.
   */
  private async waitForStableScreen(maxMs: number, pollMs: number): Promise<void> {
    let elapsed = 0;
    let prev = this.detector.screenSnapshot();
    while (elapsed < maxMs) {
      await sleep(pollMs);
      elapsed += pollMs;
      const cur = this.detector.screenSnapshot();
      if (cur !== "" && cur === prev) return;
      prev = cur;
    }
  }

  /** Poll `cond` every `pollMs` until true or `maxMs` elapses; returns whether it became true. */
  private async waitUntil(maxMs: number, pollMs: number, cond: () => boolean): Promise<boolean> {
    if (cond()) return true;
    let elapsed = 0;
    while (elapsed < maxMs) {
      await sleep(pollMs);
      elapsed += pollMs;
      if (cond()) return true;
    }
    return false;
  }

  resize(cols: number, rows: number): void {
    if (this.isRunning && cols > 0 && rows > 0) this.proc.resize(cols, rows);
    if (cols > 0 && rows > 0) this.detector.resize(cols, rows);
  }

  kill(): void {
    this.stopTitleWatch();
    this.activityTail.stop();
    if (this.isRunning) this.proc.kill();
  }

  onOutput(listener: OutputListener): () => void {
    this.outputListeners.add(listener);
    return () => this.outputListeners.delete(listener);
  }

  onExit(listener: ExitListener): () => void {
    this.exitListeners.add(listener);
    return () => this.exitListeners.delete(listener);
  }

  /**
   * Subscribe to the live rendered-screen stream — the cheap, phone-friendly
   * alternative to the raw `output` byte stream. The listener fires immediately
   * with a full-screen snapshot (`reset: true`), then with per-row diffs
   * (`reset: false`) coalesced to {@link SCREEN_FLUSH_MS}. Reads the same headless
   * screen the activity detector already maintains, so it adds no extra emulation.
   */
  onScreen(listener: ScreenListener): () => void {
    const rows = this.detector.screenRows();
    if (this.screenListeners.size === 0) this.lastScreenRows = rows;
    listener(
      rows.map((text, i) => ({ i, text })),
      rows.length,
      true,
    );
    this.screenListeners.add(listener);
    return () => this.screenListeners.delete(listener);
  }

  /** Coalesce a screen diff; cheap no-op when nobody is watching the screen. */
  private scheduleScreenFlush(): void {
    if (this.screenListeners.size === 0 || this.screenTimer) return;
    this.screenTimer = setTimeout(() => {
      this.screenTimer = null;
      this.flushScreen();
    }, SCREEN_FLUSH_MS);
  }

  /** Diff the current screen against the last frame and push only changed rows. */
  private flushScreen(): void {
    if (this.screenTimer) {
      clearTimeout(this.screenTimer);
      this.screenTimer = null;
    }
    if (this.screenListeners.size === 0) return;
    const rows = this.detector.screenRows();
    const diff: ScreenRow[] = [];
    const max = Math.max(rows.length, this.lastScreenRows.length);
    for (let i = 0; i < max; i++) {
      const text = rows[i] ?? "";
      if (text !== (this.lastScreenRows[i] ?? "")) diff.push({ i, text });
    }
    this.lastScreenRows = rows;
    if (diff.length === 0) return;
    for (const l of this.screenListeners) l(diff, rows.length, false);
  }

  /** Current inferred activity (busy / idle / waiting_input). */
  get activity(): SessionActivity {
    return this.detector.activity;
  }

  /** The pending question + options when waiting on the user, else null. */
  promptInfo(): SessionPrompt | null {
    return this.detector.extractPrompt();
  }

  /**
   * Route a decision answer back into the live pty by session id — the reply
   * channel for the `waiting_input` decision affordance (and for deep-linked
   * notification answers). Selecting an option presses its number (the CLI menus
   * activate on the digit); a free-text note is delivered with the same robust
   * bracketed-paste-then-Enter the seed path uses (a `${text}\r` burst is read as
   * a paste with the CR kept literal, so the prompt never submits).
   */
  async respond(answer: { option?: number; text?: string }): Promise<void> {
    if (!this.isRunning) throw new Error("session is not running");
    const { option } = answer;
    if (option !== undefined) {
      if (!Number.isInteger(option) || option < 1 || option > 9) {
        throw new Error("option must be an integer 1-9");
      }
      this.write(String(option));
    }
    const note = answer.text?.trim();
    if (note) {
      // After picking a menu option that opens a text field ("tell Claude what to
      // do differently"), give the TUI a beat to show the input before pasting.
      if (option !== undefined) await sleep(150);
      this.write(`\x1b[200~${note}\x1b[201~`);
      await sleep(80);
      this.write("\r");
    }
  }

  onActivity(listener: ActivityListener): () => void {
    this.activityListeners.add(listener);
    return () => this.activityListeners.delete(listener);
  }

  /** Poll the CLI's transcript so the title + token usage reflect the session. */
  private startTitleWatch(): void {
    if (this.titleTimer) return;
    this.titleTimer = setInterval(() => {
      void this.refreshTitle();
      void this.refreshUsage();
    }, TITLE_POLL_MS);
    void this.refreshTitle();
    void this.refreshUsage();
  }

  private stopTitleWatch(): void {
    if (this.titleTimer) {
      clearInterval(this.titleTimer);
      this.titleTimer = null;
    }
  }

  /** Read the CLI's generated title (or first prompt) and persist if it changed. */
  private async refreshTitle(): Promise<void> {
    const { cliSessionId, provider } = this.meta;
    if (!cliSessionId) return; // Codex id not discovered yet
    let title: string | null;
    try {
      title = await deriveSessionTitle(provider, cliSessionId);
    } catch {
      return; // best-effort; a parse/read failure just leaves the title as-is
    }
    if (title && title !== this.meta.title) {
      this.meta.title = title;
      this.persistNow();
    }
  }

  /** Read the CLI transcript's token usage and persist if it changed. */
  private async refreshUsage(): Promise<void> {
    const { cliSessionId, provider } = this.meta;
    if (!cliSessionId) return; // Codex id not discovered yet
    let usage;
    try {
      usage = await deriveSessionUsage(provider, cliSessionId);
    } catch {
      return; // best-effort; a parse/read failure leaves the usage as-is
    }
    if (usage && usage.totalTokens !== (this.meta.usage?.totalTokens ?? -1)) {
      this.meta.usage = usage;
      this.persistNow();
    }
  }

  private captureCliSessionId(): void {
    const since = Date.now();
    void captureCodexSessionId(this.meta.cwd, since)
      .then((cliSessionId) => {
        // Don't clobber a value set by a later resume, and ignore if the session
        // is long gone without ever producing a rollout file.
        if (cliSessionId && this.meta.cliSessionId === null) {
          this.meta.cliSessionId = cliSessionId;
          sessionDb.setCliSessionId(this.meta.id, cliSessionId);
        }
      })
      .catch(() => {
        // Discovery is best-effort; failure just leaves the session non-resumable.
      });
  }

  private appendScrollback(data: string): void {
    this.scrollback.append(data);
  }

  private schedulePersist(): void {
    if (this.persistTimer) return;
    this.persistTimer = setTimeout(() => {
      this.persistTimer = null;
      this.persistNow();
    }, PERSIST_DEBOUNCE_MS);
  }

  private persistNow(): void {
    if (this.persistTimer) {
      clearTimeout(this.persistTimer);
      this.persistTimer = null;
    }
    this.meta.updatedAt = Date.now();
    sessionDb.update(this.meta, this.scrollback.replay);
  }
}
