import type { SessionActivity, SessionPrompt, StructuredEvent } from "./protocol.ts";
import { TerminalScreen } from "./terminalScreen.ts";
import { parsePrompt } from "./promptParse.ts";

/**
 * Infers whether an agent session is working, has finished a turn, or is waiting
 * for the user. There are two signals, and the detector fuses them:
 *
 * 1. **Structured stream** (preferred). The CLIs write an append-only
 *    stream-json transcript as they run; new records appear *only* while the
 *    agent is actively producing a turn (an `assistant` / `thinking` / `tool_use`
 *    / `tool_result` block). {@link Session} tails that transcript and calls
 *    {@link feedStructured} with each batch of normalized events. A batch that
 *    carries any agent-produced event is an unambiguous "the agent is working"
 *    pulse that does not depend on rendered TUI wording at all — robust to CLI
 *    footer/spinner copy changes. This is the headline of juancode-doq.
 *
 * 2. **Rendered PTY screen** (fallback). The raw pty byte stream is fed into a
 *    headless {@link TerminalScreen}, so the detector can read the *actual
 *    rendered screen*. Both `claude` and `codex` paint an "esc to interrupt"
 *    footer while a turn runs and an option-menu / yes-no prompt when they pause
 *    for the user. This path still drives **busy** when no transcript is
 *    available (e.g. before the CLI session id is known, or a provider/mode that
 *    writes no transcript), and — crucially — it is what distinguishes
 *    **waiting_input** from **idle** at turn end, since a permission prompt is
 *    *not* written to the transcript until the user answers it.
 *
 * In both cases the lifecycle is the same: a busy pulse (re)arms a short settle
 * timer and a long watchdog. On settle we re-read the rendered screen — an
 * option menu / yes-no prompt visible => **waiting_input**, otherwise **idle**
 * (unless the working footer is still up *and* we have no structured turn-end
 * yet, in which case we stay busy). The watchdog demotes a stuck busy if both
 * streams go silent.
 *
 * Because busy is only ever entered via a working footer or a structured agent
 * event, the startup banner and the user's own keystroke echoes — which carry
 * neither — are never mistaken for agent activity. Best-effort: with no
 * transcript, a CLI footer-wording change can still defeat the screen patterns,
 * which is exactly why the structured path exists.
 */

/** Quiet period after a busy pulse before we re-classify the screen. */
const SETTLE_MS = 250;
/** Longer silence after which a still-"busy" session is treated as stale. */
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

/**
 * Structured-event kinds that mean the agent is actively producing a turn. A
 * `user` record is the user's own prompt landing — also a turn boundary, but it
 * doesn't by itself mean the agent is working, so it is excluded here (the
 * agent's first `assistant`/`thinking`/`tool_use` record that follows is the
 * busy pulse).
 */
const AGENT_EVENT_KINDS: ReadonlySet<StructuredEvent["kind"]> = new Set([
  "assistant",
  "thinking",
  "tool_use",
  "tool_result",
]);

/** True when a batch of normalized events contains an agent-produced record. */
export function batchHasAgentActivity(events: readonly StructuredEvent[]): boolean {
  return events.some((e) => AGENT_EVENT_KINDS.has(e.kind));
}

type ChangeListener = (state: SessionActivity, notify: boolean) => void;

export class ActivityDetector {
  private state: SessionActivity = "idle";
  private readonly screen: TerminalScreen;
  private settleTimer: NodeJS.Timeout | null = null;
  private watchdogTimer: NodeJS.Timeout | null = null;
  /**
   * Whether the *current* busy turn was started by a structured agent event.
   * When true we don't keep the turn busy just because the footer regex still
   * matches — the transcript is authoritative, so settle classifies on the
   * screen's prompt/quiet state instead of waiting for the footer to be erased.
   * Reset whenever we leave busy.
   */
  private structuredTurn = false;

  constructor(
    cols: number,
    rows: number,
    private readonly onChange: ChangeListener,
  ) {
    this.screen = new TerminalScreen(cols, rows);
  }

  /** Feed a chunk of raw pty output (the screen / fallback signal). */
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
        this.structuredTurn = false;
        this.transition("busy", false);
        this.armTimers();
      }
    }
    // Idle with no possible footer: nothing to do (don't reclassify idle output
    // into waiting_input — active states are only entered via a working turn).
  }

  /**
   * Feed a batch of normalized structured events from the session's transcript
   * tail (the preferred signal). A batch carrying an agent-produced record is a
   * wording-independent "the agent is working" pulse: it enters/keeps busy and
   * (re)arms the settle/watchdog clocks exactly like footer output does.
   */
  feedStructured(events: readonly StructuredEvent[]): void {
    if (!batchHasAgentActivity(events)) return;
    // A structured pulse is authoritative for this turn, whether it starts the
    // turn or upgrades one the screen path already opened (so settle no longer
    // waits on the footer being erased).
    this.structuredTurn = true;
    if (this.state !== "busy") this.transition("busy", false);
    this.armTimers();
  }

  get activity(): SessionActivity {
    return this.state;
  }

  /**
   * The pending question + options parsed from the current screen when the
   * session is waiting on the user, else null. Best-effort (see `promptParse.ts`)
   * and only meaningful while `waiting_input`.
   */
  extractPrompt(): SessionPrompt | null {
    if (this.state !== "waiting_input") return null;
    return parsePrompt(this.screen.visibleText);
  }

  /**
   * A snapshot of the whole rendered screen — used by {@link Session.autoSubmit}
   * to detect when the TUI has settled (stable frames) before pasting.
   */
  screenSnapshot(): string {
    return this.screen.visibleText;
  }

  /**
   * Every rendered row of the screen (stable count, trailing spaces trimmed) —
   * the source for the live phone screen stream (see `Session.onScreen`).
   */
  screenRows(): string[] {
    return this.screen.rows();
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
    this.structuredTurn = false;
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
   * anyway, so we never hang on busy after both streams have gone silent.
   *
   * The footer regex only *holds* a turn busy when the turn was driven by the
   * screen path (no structured signal). A structured turn settles on the screen's
   * prompt/quiet state directly: the transcript already told us the agent stopped
   * emitting, so a footer the CLI hasn't repainted yet must not pin us busy.
   */
  private settle(demoteStaleFooter: boolean): void {
    if (this.state !== "busy") return;
    const text = this.normalizedScreen();
    let next: SessionActivity;
    if (!demoteStaleFooter && !this.structuredTurn && WORKING_RE.test(text)) {
      next = "busy"; // still working (screen path) — leave it
    } else {
      next = PROMPT_RES.some((re) => re.test(text)) ? "waiting_input" : "idle";
    }
    // We're leaving busy on a real turn boundary, so notify.
    this.transition(next, next !== "busy");
  }

  private transition(state: SessionActivity, notify: boolean): void {
    if (state === this.state) return;
    this.state = state;
    if (state !== "busy") this.structuredTurn = false;
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
