import type { SessionActivity } from "./protocol.ts";

/**
 * Infers whether an agent session is working, has finished a turn, or is waiting
 * for the user — from the raw pty byte stream alone (we never reimplement the
 * agents, so this is all we have).
 *
 * The signal: both `claude` and `codex` show an "esc to interrupt" status line
 * while they work. They paint that phrase *once* when a turn starts and then
 * only update the changing bits (the elapsed-time counter, token counts) via
 * cursor moves — so the phrase itself is not re-emitted every frame. We use it
 * only to *enter* `busy`; from there any continued output (the ticking timer,
 * streaming tokens) keeps the session busy, and we settle once output goes quiet
 * for `SETTLE_MS`. Because a session can only become busy via the phrase, the
 * startup banner and the user's own keystroke echoes — which never contain it —
 * are never mistaken for agent activity, so we don't fire spurious pings.
 *
 * When a turn settles we classify the final screen: an interactive option menu
 * or yes/no prompt means the agent is waiting for input; anything else means the
 * turn is simply done. This classification is best-effort (it matches Claude's
 * permission menus and common prompts) and a CLI wording change can defeat it —
 * the robust long-term path is the structured stream-json view (juancode-4jq).
 */

/** Grace period after the working indicator stops repainting before we settle. */
const SETTLE_MS = 1200;
/** How much of the (ANSI-stripped) recent screen we keep for classification. */
const TAIL_LIMIT = 4000;

/** The "esc to interrupt" working line, tolerant of wording ("Esc again to…"). */
const WORKING_RE = /\besc(?:ape)?\b[^\n]{0,40}\binterrupt\b/i;

/** CSI/OSC escape sequences + lone control bytes, stripped before matching. */
// eslint-disable-next-line no-control-regex
const ANSI_RE = /\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[\]P][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[()][AB0-2]|\x1b[=>]|[\x00-\x08\x0b\x0c\x0e-\x1f]/g;

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
  private tail = "";
  private settleTimer: NodeJS.Timeout | null = null;

  constructor(private readonly onChange: ChangeListener) {}

  /** Feed a chunk of raw pty output. */
  feed(data: string): void {
    const stripped = data.replace(ANSI_RE, "");
    if (stripped) this.tail = (this.tail + stripped).slice(-TAIL_LIMIT);
    // The phrase is matched against the current frame only (not the historical
    // tail) so it genuinely marks the *start* of a turn — a stale occurrence
    // can't make typing echoes re-trigger busy later.
    if (WORKING_RE.test(stripped)) {
      this.markBusy();
    } else if (this.state === "busy") {
      // The CLIs don't re-emit the phrase each frame; once a turn is underway any
      // further output (ticking timer, streaming tokens) keeps it alive. We only
      // settle when the stream actually goes quiet.
      this.armSettle();
    }
  }

  get activity(): SessionActivity {
    return this.state;
  }

  /** The session ended — clear any pending settle and return to idle. */
  reset(): void {
    this.clearTimer();
    this.transition("idle", false);
  }

  private markBusy(): void {
    this.transition("busy", false);
    this.armSettle();
  }

  /** (Re)start the quiet-period timer that ends the current busy turn. */
  private armSettle(): void {
    this.clearTimer();
    this.settleTimer = setTimeout(() => this.settle(), SETTLE_MS);
  }

  private settle(): void {
    this.settleTimer = null;
    const recent = this.tail.slice(-2000);
    const next: SessionActivity = PROMPT_RES.some((re) => re.test(recent))
      ? "waiting_input"
      : "idle";
    // A settle always follows a busy period, so this is a real turn boundary:
    // notify even when classifying back to idle.
    this.transition(next, true);
  }

  private transition(state: SessionActivity, notify: boolean): void {
    if (state === this.state) return;
    this.state = state;
    this.onChange(state, notify);
  }

  private clearTimer(): void {
    if (this.settleTimer) {
      clearTimeout(this.settleTimer);
      this.settleTimer = null;
    }
  }
}
