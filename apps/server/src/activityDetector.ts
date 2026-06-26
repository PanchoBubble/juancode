import type { SessionActivity } from "./protocol.ts";
import { TerminalScreen } from "./terminalScreen.ts";

/**
 * Infers whether an agent session is working, has finished a turn, or is waiting
 * for the user — from the raw pty byte stream alone (we never reimplement the
 * agents, so this is all we have).
 *
 * The stream is fed into a headless {@link TerminalScreen}, so the detector reads
 * the *actual rendered screen* rather than a flattened byte tail. Both `claude`
 * and `codex` paint an "esc to interrupt" footer once when a turn starts and then
 * only update the changing bits (the elapsed-time counter, token counts) via
 * cursor moves — the phrase itself is not re-emitted every frame. A concatenated
 * tail therefore can't tell whether the footer is still on screen, which is the
 * whole question; the grid can, because the footer occupies real cells until the
 * CLI erases them at turn end. So:
 *
 * - **busy** while the working footer is visible in the current frame.
 * - on a brief quiet period we re-read the screen: footer gone + an option menu /
 *   yes-no prompt visible => **waiting_input**; footer gone + nothing => **idle**.
 * - a longer watchdog demotes a stuck **busy** if the footer somehow lingers but
 *   the spinner has stopped emitting (the timer repaints ~1/s while truly busy,
 *   so prolonged total silence means the turn really ended).
 *
 * Because a session can only become busy via the footer phrase, the startup
 * banner and the user's own keystroke echoes — which never contain it — are never
 * mistaken for agent activity. Best-effort: a CLI wording change can defeat the
 * footer / prompt patterns.
 */

/** Quiet period after output stops before we re-classify the screen. */
const SETTLE_MS = 250;
/** Longer silence after which a still-"busy" footer is treated as stale. */
const WATCHDOG_MS = 8000;

/** The "esc to interrupt" working line, tolerant of wording ("Esc again to…"). */
const WORKING_RE = /\besc(?:ape)?\b[^\n]{0,40}\binterrupt\b/i;

/** Runs of intra-line whitespace (not newlines), collapsed before matching. */
const WS_RE = /[^\S\n]{2,}/g;

/**
 * Markers that a settled screen is an interactive question awaiting a choice
 * rather than a completed turn. The `❯ 1.` cursor is Claude/Codex's own
 * selection UI (prose lists never carry it); the rest catch plain prompts.
 */
const PROMPT_RES: readonly RegExp[] = [
  /❯\s*\d+\.\s/, // selection cursor on a numbered option (permission menus)
  /\bDo you want to\b/i,
  /\bProceed\?/i,
  /\(y\/n\)/i,
  /\[y\/n\]/i,
  /\bAllow\b[^\n]{0,40}\?/i,
];

type ChangeListener = (state: SessionActivity, notify: boolean) => void;

export class ActivityDetector {
  private state: SessionActivity = "idle";
  private readonly screen: TerminalScreen;
  private settleTimer: NodeJS.Timeout | null = null;
  private watchdogTimer: NodeJS.Timeout | null = null;

  constructor(
    cols: number,
    rows: number,
    private readonly onChange: ChangeListener,
  ) {
    this.screen = new TerminalScreen(cols, rows);
  }

  /** Feed a chunk of raw pty output. */
  feed(data: string): void {
    // The screen must see every byte to stay an accurate mirror.
    this.screen.feed(data);
    if (this.state === "busy") {
      // Already working: any output (re)starts the settle/watchdog clocks.
      this.armTimers();
    } else if (data.toLowerCase().includes("interrupt")) {
      // Cheap gate: only a frame that could carry the working footer is worth
      // re-reading the screen for. If the footer is now visible we go busy.
      if (WORKING_RE.test(this.normalizedScreen())) {
        this.transition("busy", false);
        this.armTimers();
      }
    }
    // Idle with no possible footer: nothing to do (don't reclassify idle output
    // into waiting_input — active states are only entered via a working turn).
  }

  get activity(): SessionActivity {
    return this.state;
  }

  /**
   * A snapshot of the whole rendered screen — used by {@link Session.autoSubmit}
   * to detect when the TUI has settled (stable frames) before pasting.
   */
  screenSnapshot(): string {
    return this.screen.visibleText;
  }

  /**
   * The bottom `rows` of the rendered screen — the footer / input-box region — so
   * {@link Session.autoSubmit} can confirm a seeded prompt landed in (or left) the
   * input box without matching the same text echoed up in the conversation.
   */
  inputRegionSnapshot(rows: number): string {
    return this.screen.bottomText(rows);
  }

  /** Keep the screen model in step with the pty size. Called from Session.resize. */
  resize(cols: number, rows: number): void {
    this.screen.resize(cols, rows);
  }

  /** The session ended — cancel any pending timers and return to idle. */
  reset(): void {
    this.clearTimers();
    this.transition("idle", false);
  }

  /** (Re)arm both the short settle timer and the long stuck-busy watchdog. */
  private armTimers(): void {
    this.clearTimers();
    this.settleTimer = setTimeout(() => {
      this.settleTimer = null;
      this.settle(false);
    }, SETTLE_MS);
    this.watchdogTimer = setTimeout(() => {
      this.watchdogTimer = null;
      this.settle(true);
    }, WATCHDOG_MS);
  }

  /**
   * Re-read the screen and classify. Only meaningful while busy: it ends a turn.
   * `demoteStaleFooter` (the watchdog path) ignores a lingering footer and settles
   * anyway, so we never hang on busy after the spinner has gone silent.
   */
  private settle(demoteStaleFooter: boolean): void {
    if (this.state !== "busy") return;
    const text = this.normalizedScreen();
    let next: SessionActivity;
    if (!demoteStaleFooter && WORKING_RE.test(text)) {
      next = "busy"; // still working — leave it
    } else {
      next = PROMPT_RES.some((re) => re.test(text)) ? "waiting_input" : "idle";
    }
    // We're leaving busy on a real turn boundary, so notify.
    this.transition(next, next !== "busy");
  }

  private transition(state: SessionActivity, notify: boolean): void {
    if (state === this.state) return;
    this.state = state;
    this.onChange(state, notify);
  }

  /**
   * The visible screen with runs of intra-line whitespace collapsed to a single
   * space. The grid renders cursor-positioned footer segments as the *actual*
   * column gap (many spaces); collapsing restores a compact line so the
   * distance-bounded WORKING_RE (`[^\n]{0,40}`) matches as intended.
   */
  private normalizedScreen(): string {
    return this.screen.visibleText.replace(WS_RE, " ");
  }

  private clearTimers(): void {
    if (this.settleTimer) {
      clearTimeout(this.settleTimer);
      this.settleTimer = null;
    }
    if (this.watchdogTimer) {
      clearTimeout(this.watchdogTimer);
      this.watchdogTimer = null;
    }
  }
}
