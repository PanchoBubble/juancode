import { randomUUID } from "node:crypto";
import { basename } from "node:path";
import * as pty from "node-pty";
import { SCROLLBACK_LIMIT } from "./config.ts";
import { getLoginEnv } from "./loginEnv.ts";
import { Scrollback } from "./scrollback.ts";
import { captureCodexSessionId } from "./codexSession.ts";
import { sessionDb } from "./db.ts";
import { PROVIDERS } from "./providers.ts";
import type { SpawnOptions } from "./providers.ts";
import { deriveSessionTitle } from "./sessionTitle.ts";
import { deriveSessionUsage } from "./sessionUsage.ts";
import { ActivityDetector } from "./activityDetector.ts";
import { GridArbiter } from "./gridArbiter.ts";
import { notificationGate } from "./notificationGate.ts";
import { messageQueue } from "./messageQueue.ts";
import { TranscriptTail } from "./structuredTranscript.ts";
import {
  promptSignature,
  regionContains,
  regionShowsCollapsedPaste,
} from "./initialPromptDelivery.ts";
import type {
  ProviderId,
  ScreenRow,
  SessionActivity,
  SessionMeta,
  SessionPrompt,
} from "./protocol.ts";

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

/** Tunables for delivering queued messages on an idle transition (oracle-cj3). */
const QUEUE = {
  /** Pause between pasting the text and the submitting Enter (let the TUI catch up). */
  pasteToEnterMs: 80,
  /** How long to confirm a delivered message took (the agent went busy). */
  acceptMs: 4000,
  pollMs: 120,
} as const;

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

/**
 * Server-owned desired-grid re-apply (juancode-1th.3). A freshly-spawned CLI boots
 * at the grid we passed `pty.spawn` but may install its SIGWINCH handler only after
 * a slow boot (MCP servers loading for seconds), missing early resizes and staying
 * at the wrong size. Rather than have every client paper over this with its own
 * retry timers, the server re-asserts the desired grid a few times across the boot
 * window — forcing a genuine SIGWINCH each time — until the settled CLI adopts it.
 */
const GRID = {
  /** Settle-check rounds across the boot window; the nudge fires at most once,
   * on the first round whose screen genuinely settles. */
  reapplyAttempts: 3,
  /** Per-round budget for the TUI to settle (stable frames). */
  settleMaxMs: 8_000,
  settlePollMs: 200,
  /** Gap between the `rows-1` nudge and the real `rows` (a genuine size change). */
  nudgeMs: 60,
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
  /** Previous activity, tracked to fire the queue flush on the edge into idle. */
  private prevQueueActivity: SessionActivity | undefined;
  /** True while {@link flushQueue} is mid-delivery, so edges don't overlap it. */
  private flushingQueue = false;
  private readonly detector: ActivityDetector;
  /**
   * Arbitrates which client controls this session's single shared pty grid, so
   * two different-sized viewers can't flap it last-write-wins (juancode-1th.1).
   */
  private readonly grid = new GridArbiter();
  /**
   * The controlling client's most recent desired grid, seeded with the spawn size
   * and updated on every arbitrated resize. The server re-asserts it across the
   * boot window so a CLI that installs its SIGWINCH handler late still lands at the
   * right size — no client-side retry timers needed (juancode-1th.3).
   */
  private desiredCols = 0;
  private desiredRows = 0;
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
      this.maybeFlushQueueOnEdge(state);
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
      // Inherit the user's FULL login-shell environment (captured once at first
      // spawn) so the CLI loads the same PATH, auth, and MCP-relevant vars it
      // would in a terminal — even when juancode was launched from a GUI/launchd
      // context with a stripped env. We spawn the CLI binary directly (no shell),
      // so without this it would only get this process's env. This augments, never
      // shadows: HOME/CODEX_HOME and the user's config are left untouched.
      env: getLoginEnv(),
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
    // Seed the desired grid with the spawn size and re-assert it once the TUI is
    // up, so a slow-booting CLI that missed early SIGWINCHs still adopts it
    // (juancode-1th.3) — the server-side replacement for per-client retry timers.
    this.desiredCols = cols;
    this.desiredRows = rows;
    void this.reapplyGridWhenReady();
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
      if (!this.isRunning)
        return { ok: false, reason: "session exited before the prompt was typed" };
      if (this.isBusy()) return { ok: true }; // already working
      this.write(`\x1b[200~${trimmed}\x1b[201~`);
      landed = await this.waitUntil(
        SEED.landMs,
        SEED.pollMs,
        () =>
          this.isBusy() || this.inputBoxContains(signature) || this.inputBoxShowsCollapsedPaste(),
      );
      if (this.isBusy()) return { ok: true };
      if (landed) break;
    }
    if (!landed) {
      return {
        ok: false,
        reason: `the prompt never appeared in the input box after ${SEED.maxAttempts} tries`,
      };
    }

    // 3) Submit, then confirm it went through (agent busy, or the box cleared).
    for (let i = 0; i < SEED.maxAttempts; i++) {
      if (!this.isRunning)
        return { ok: false, reason: "session exited before the prompt was submitted" };
      this.write("\r");
      const submitted = await this.waitUntil(
        SEED.submitMs,
        SEED.pollMs,
        () =>
          this.isBusy() ||
          (!this.inputBoxContains(signature) && !this.inputBoxShowsCollapsedPaste()),
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
   * True if the input-box region shows a collapsed-paste chip (Claude renders one
   * for a large/multi-line paste in place of the literal text), which the seed loop
   * treats as the paste having landed. See {@link regionShowsCollapsedPaste}.
   */
  private inputBoxShowsCollapsedPaste(): boolean {
    return regionShowsCollapsedPaste(this.detector.inputRegionSnapshot(SEED.inputRows));
  }

  /**
   * Resolve once the rendered screen stops changing (two identical, non-empty
   * frames `pollMs` apart) or `maxMs` elapses — a CLI-agnostic "TUI is ready"
   * signal that replaces trusting the first output byte. Resolves with whether
   * the screen actually settled (false = still changing at `maxMs`), so a caller
   * can tell "ready" from "busy streaming" and avoid disturbing the latter.
   */
  private async waitForStableScreen(maxMs: number, pollMs: number): Promise<boolean> {
    let elapsed = 0;
    let prev = this.detector.screenSnapshot();
    while (elapsed < maxMs) {
      await sleep(pollMs);
      elapsed += pollMs;
      const cur = this.detector.screenSnapshot();
      if (cur !== "" && cur === prev) return true;
      prev = cur;
    }
    return false;
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

  /** Resize the pty grid. Returns whether the grid reached the live pty (false
   * when the session isn't running yet — the resize is then dropped and the
   * caller can ack that so a sequenced client re-asserts, juancode-uz6). */
  resize(cols: number, rows: number): boolean {
    const applied = this.isRunning && cols > 0 && rows > 0;
    if (applied) this.proc.resize(cols, rows);
    if (cols > 0 && rows > 0) this.detector.resize(cols, rows);
    return applied;
  }

  /**
   * Arbitrated grid resize for a specific client (juancode-1th.1). Only the
   * *controlling* owner may write the shared pty grid; a non-owner's request is
   * denied so the CLI TUI never flaps between two viewers' sizes. `applied` is
   * whether the grid reached a live pty (as {@link resize}); `denied` is true when
   * another client owns the grid — the caller should render the pty's actual grid
   * as-is, and the `resizeAck.denied` flag tells its tracker to stop retrying.
   */
  resizeGrid(owner: string, cols: number, rows: number): { applied: boolean; denied: boolean } {
    if (!this.grid.request(owner)) return { applied: false, denied: true };
    // Remember the controlling owner's grid so the server can re-assert it if this
    // resize raced the CLI's SIGWINCH-handler install (juancode-1th.3).
    if (cols > 0 && rows > 0) {
      this.desiredCols = cols;
      this.desiredRows = rows;
    }
    return { applied: this.resize(cols, rows), denied: false };
  }

  /**
   * Re-assert the desired grid once the TUI is up (juancode-1th.3). A CLI that
   * installs its SIGWINCH handler late (slow MCP load) can miss a resize that
   * landed during boot; once the screen settles, one genuine SIGWINCH makes it
   * re-read the size — and one is enough, a settled TUI is fully initialized.
   * The nudge fires ONLY on a genuinely settled screen: forcing it into a CLI
   * that's actively streaming (resumed mid-turn, auto-submitted prompt) makes the
   * TUI full-redraw twice mid-stream and lands mis-rendered frames in scrollback
   * permanently — the "terminal garbles without any resize" bug. If the screen
   * never settles across the rounds, skip entirely: a streaming CLI is
   * demonstrably rendering, and any later real client resize re-asserts the grid
   * anyway. Runs server-side so no client needs its own retry timers.
   */
  private async reapplyGridWhenReady(): Promise<void> {
    for (let i = 0; i < GRID.reapplyAttempts; i++) {
      const settled = await this.waitForStableScreen(GRID.settleMaxMs, GRID.settlePollMs);
      if (!this.isRunning) return;
      if (settled) {
        this.nudgeReapply();
        return;
      }
    }
  }

  /**
   * Push the desired grid to the pty as a `rows-1` → `rows` pair: a genuine size
   * change forces a SIGWINCH the settled CLI can't miss, where re-sending the same
   * size can be a no-op. No-op until a desired grid is known / the pty is live.
   */
  private nudgeReapply(): void {
    const cols = this.desiredCols;
    const rows = this.desiredRows;
    if (!this.isRunning || cols <= 0 || rows <= 0) return;
    this.resize(cols, rows > 2 ? rows - 1 : rows + 1);
    setTimeout(() => {
      if (this.isRunning) this.resize(cols, rows);
    }, GRID.nudgeMs);
  }

  /**
   * Release this session's grid ownership held by `owner` — its client
   * disconnected (or its view was torn down) — so the next client's resize can
   * take over the grid (juancode-1th.1). No-op if `owner` isn't the current owner.
   */
  releaseGrid(owner: string): void {
    this.grid.release(owner);
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
      await this.pasteAndSubmit(note);
    }
  }

  onActivity(listener: ActivityListener): () => void {
    this.activityListeners.add(listener);
    return () => this.activityListeners.delete(listener);
  }

  /**
   * Inject `text` into a *running* session right now to redirect it mid-task —
   * the interrupt-and-steer path, as opposed to {@link kickQueue}/{@link flushQueue}
   * which line a message up for the next idle turn boundary. The CLIs accept input
   * while the agent is working (Claude Code reads typed-and-submitted text as a
   * steering instruction for the current turn), so we deliver it with the same
   * bracketed-paste-then-Enter primitive the seed / queue / decision paths use.
   * Throws if the session isn't live so the caller can surface it.
   */
  async steer(text: string): Promise<void> {
    const trimmed = text.trim();
    if (!trimmed) return;
    if (!this.isRunning) throw new Error("session is not running");
    await this.pasteAndSubmit(trimmed);
  }

  /**
   * Bracketed-paste `text` into the pty and submit it with a lone Enter. The
   * split — paste (`ESC[200~ … ESC[201~`) then a *separate* CR — is essential: a
   * `${text}\r` burst is read as a paste with the CR kept literal, so the prompt
   * never submits. Shared by the seed, queue, decision-reply, and steer paths.
   */
  private async pasteAndSubmit(text: string, pauseMs = QUEUE.pasteToEnterMs): Promise<void> {
    this.write(`\x1b[200~${text}\x1b[201~`);
    await sleep(pauseMs);
    if (!this.isRunning) return;
    this.write("\r");
  }

  /**
   * Nudge the queue when a message is added while the session is already idle —
   * otherwise the next message would wait for an activity edge that never comes.
   * Safe to call any time; it no-ops unless idle with something to deliver.
   */
  kickQueue(): void {
    if (this.isRunning && this.activity === "idle") void this.flushQueue();
  }

  /** Fire the queue flush only on a real transition *into* idle (turn boundary). */
  private maybeFlushQueueOnEdge(state: SessionActivity): void {
    const was = this.prevQueueActivity;
    this.prevQueueActivity = state;
    if (state === "idle" && was !== undefined && was !== "idle") void this.flushQueue();
  }

  /**
   * Deliver queued messages (ticket oracle-cj3) one at a time while the session
   * sits idle. Each is sent with the same bracketed-paste-then-Enter the seed and
   * decision-reply paths use (a `${text}\r` burst is read as a paste with the CR
   * kept literal, so it never submits). We pop a message only once we've confirmed
   * it landed the agent in `busy`; that also ends this pass — the agent finishing
   * the turn fires the next idle edge, which delivers the next message in order.
   */
  private async flushQueue(): Promise<void> {
    if (this.flushingQueue) return;
    this.flushingQueue = true;
    try {
      while (this.isRunning && this.activity === "idle") {
        const item = messageQueue.peek(this.meta.id);
        if (!item) break;
        await this.pasteAndSubmit(item.text);
        if (!this.isRunning) break;
        const accepted = await this.waitUntil(
          QUEUE.acceptMs,
          QUEUE.pollMs,
          () => this.isBusy() || !this.isRunning,
        );
        // Drop the message only once it actually took; otherwise leave it queued
        // and stop, so a stalled delivery is retried on the next idle/kick rather
        // than spun on in a hot loop.
        if (accepted && this.isBusy()) {
          messageQueue.remove(this.meta.id, item.id);
        }
        break;
      }
    } finally {
      this.flushingQueue = false;
    }
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
