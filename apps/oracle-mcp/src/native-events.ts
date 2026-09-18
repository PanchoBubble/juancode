// Native-backend session-event listener for the Oracle sidecar. Owns the single
// long-lived WebSocket client to the native app's embedded server and re-emits
// every `activity` broadcast to in-process subscribers (the Telegram bridge),
// plus opt-in rendered-`screen` frames to per-session viewers (juancode-a2h.3).
//
// The native Hummingbird server (127.0.0.1:4280, ws path /ws) broadcasts
// `activity` for every session automatically on connect (no subscribe needed —
// see WebSocketConnection.start()), so we just connect and fan those out.

import { WebSocket } from "ws";

/** Resolve the native backend's WS URL from the same base oracle.ts uses for its
 *  HTTP calls. Kept local (oracle.ts doesn't export nativeApiBase). */
function nativeHttpBase(): string {
  return process.env.JUANCODE_API
    ? process.env.JUANCODE_API.replace(/\/$/, "")
    : `http://127.0.0.1:${process.env.JUANCODE_PORT || "4280"}`;
}

function nativeWsUrl(): string {
  return nativeHttpBase().replace(/^http/, "ws") + "/ws";
}

// ── Session-event fan-out (juancode-2l4) ─────────────────────────────────────
// This module owns the one long-lived WS to the native backend; consumers (the
// Telegram bridge) subscribe here instead of opening their own socket. Every
// `activity` broadcast is re-emitted — including notify:false ones, so subscribers
// can keep a warm per-session state cache — and the `notify` flag carries the
// server's de-spam gate through unchanged.

/** Whole-tree change rollup a settled turn left behind (files changed, line
 *  additions/deletions vs HEAD). Mirrors the native `ChangeStat`, minus its
 *  desktop-local debounce signature. */
export interface SessionChanges {
  files: number;
  additions: number;
  deletions: number;
}

export interface SessionActivityEvent {
  sessionId: string;
  state: "busy" | "idle" | "waiting_input";
  notify: boolean;
  /** Attached by the native server only on the settle edge (a turn finishing
   *  over a dirty tree — when the desktop change badge appears); absent otherwise. */
  changes?: SessionChanges;
  /** The Oracle dispatch this session was spawned from (persisted on its
   *  SessionMeta), so lifecycle events route back to the dispatching chat;
   *  absent for interactive sessions. */
  dispatchId?: string;
}

/** A stuck-session advisory (juancode-1vo0): the daemon noticed a session going
 *  nowhere — the same tool call repeated with identical canonicalised arguments, or a
 *  claim to be working with no transcript record and no output behind it.
 *
 *  Advisory only. The daemon has already decided to do nothing about it: nothing is
 *  killed, nothing is typed into the pty, and `advice` is a sentence for a human. It
 *  is broadcast unsolicited, like `activity`, so there is nothing to subscribe to.
 *
 *  Only the rust core sends it (wire capability `stuck`); the Swift core has no
 *  transcript seam, so under that backend this never arrives and nothing breaks. */
export interface SessionStuckEvent {
  sessionId: string;
  kind: "repeat" | "stall";
  /** The tool a repeat run is on; absent for a stall. */
  tool?: string;
  /** Consecutive identical calls; 0 for a stall. */
  run: number;
  /** How long the session has been dormant while claiming to work; 0 for a repeat. */
  quietMs: number;
  /** The whole message. Arguments in it are already head-truncated server-side. */
  advice: string;
  dispatchId?: string;
}

/** Parse a raw WS message object into a SessionStuckEvent, or null if it isn't one.
 *  Lenient like the rest of this module: a malformed frame is dropped, not thrown. */
export function parseStuckEvent(msg: Record<string, unknown>): SessionStuckEvent | null {
  if (msg.type !== "stuck") return null;
  if (typeof msg.sessionId !== "string" || !msg.sessionId) return null;
  if (msg.kind !== "repeat" && msg.kind !== "stall") return null;
  if (typeof msg.advice !== "string" || !msg.advice) return null;
  const ev: SessionStuckEvent = {
    sessionId: msg.sessionId,
    kind: msg.kind,
    run: typeof msg.run === "number" ? msg.run : 0,
    quietMs: typeof msg.quietMs === "number" ? msg.quietMs : 0,
    advice: msg.advice,
  };
  if (typeof msg.tool === "string" && msg.tool) ev.tool = msg.tool;
  if (typeof msg.dispatchId === "string" && msg.dispatchId) ev.dispatchId = msg.dispatchId;
  return ev;
}

/** A per-session usage reading (juancode-lncw), lifted off the `sessionMeta`
 *  frames the endpoint already broadcasts on every usage poll — so this costs no
 *  new wire message and nothing in any request path.
 *
 *  `contextTokens` is what the live conversation currently occupies of the model's
 *  window (the newest turn's input + cache tokens), NOT the cumulative
 *  `totalTokens`, which only grows. `contextWindow` comes from the price/window
 *  table in the Swift core — the sidecar never sees a model id, so it never has to
 *  keep a copy of that table. Either half can be absent (an unknown model, a core
 *  with no usage seam), and then `contextFraction` is absent too rather than 0. */
export interface SessionUsageSample {
  sessionId: string;
  totalTokens: number;
  /** Estimated spend to date, absent when the model was unpriced. */
  costUsd?: number;
  contextTokens?: number;
  contextWindow?: number;
  /** contextTokens / contextWindow; absent when either half is. */
  contextFraction?: number;
  dispatchId?: string;
}

/** Pull the usage block off a `sessionMeta` frame, or null when the frame isn't one
 *  / carries no usage yet. Lenient like the rest of this module: a malformed frame
 *  is dropped, not thrown. */
export function parseUsageSample(msg: Record<string, unknown>): SessionUsageSample | null {
  if (msg.type !== "sessionMeta") return null;
  const session = msg.session;
  if (typeof session !== "object" || session === null) return null;
  const meta = session as Record<string, unknown>;
  const sessionId = typeof meta.id === "string" ? meta.id : "";
  if (!sessionId) return null;
  const usage = meta.usage;
  if (typeof usage !== "object" || usage === null) return null;
  const u = usage as Record<string, unknown>;
  if (typeof u.totalTokens !== "number") return null;
  const sample: SessionUsageSample = { sessionId, totalTokens: u.totalTokens };
  if (typeof u.costUsd === "number") sample.costUsd = u.costUsd;
  if (typeof u.contextTokens === "number") sample.contextTokens = u.contextTokens;
  if (typeof u.contextWindow === "number" && u.contextWindow > 0) {
    sample.contextWindow = u.contextWindow;
  }
  if (sample.contextTokens !== undefined && sample.contextWindow !== undefined) {
    sample.contextFraction = sample.contextTokens / sample.contextWindow;
  }
  if (typeof meta.dispatchId === "string" && meta.dispatchId) sample.dispatchId = meta.dispatchId;
  return sample;
}

type UsageListener = (sample: SessionUsageSample) => void;
const usageListeners: UsageListener[] = [];

/** Subscribe to per-session usage readings. Fires on every meta update that carries
 *  usage — deciding which of those is worth a ping is the consumer's job
 *  (`usage-alerts.ts` latches one alert per crossing). Listener errors are isolated. */
export function onSessionUsage(listener: UsageListener): void {
  usageListeners.push(listener);
}

function emitUsageSample(sample: SessionUsageSample): void {
  for (const listener of usageListeners) {
    try {
      listener(sample);
    } catch (e) {
      console.warn("oracle-mcp usage listener failed:", e instanceof Error ? e.message : e);
    }
  }
}

type SessionEventListener = (ev: SessionActivityEvent) => void;
const sessionEventListeners: SessionEventListener[] = [];

type StuckListener = (ev: SessionStuckEvent) => void;
const stuckListeners: StuckListener[] = [];

/** Subscribe to stuck-session advisories. Listener errors are isolated. */
export function onSessionStuck(listener: StuckListener): void {
  stuckListeners.push(listener);
}

function emitStuckEvent(ev: SessionStuckEvent): void {
  for (const listener of stuckListeners) {
    try {
      listener(ev);
    } catch (e) {
      console.warn("oracle-mcp stuck listener failed:", e instanceof Error ? e.message : e);
    }
  }
}

/** Subscribe to native session activity events. Listener errors are isolated. */
export function onSessionEvent(listener: SessionEventListener): void {
  sessionEventListeners.push(listener);
}

function emitSessionEvent(ev: SessionActivityEvent): void {
  for (const listener of sessionEventListeners) {
    try {
      listener(ev);
    } catch (e) {
      console.warn("oracle-mcp session event listener failed:", e instanceof Error ? e.message : e);
    }
  }
}

// ── Rendered-screen stream (juancode-a2h.3) ──────────────────────────────────
// TS mirror of the native server's `screen` wire frames (see ScreenWire.swift /
// WireProtocol.swift — keep both sides in sync). A screen viewer renders these
// rows directly: no client-side terminal emulator, and — because subscribing is
// read-only server-side — no participation in the desktop's grid ownership.

/** One styled run of a row. `fg`/`bg`: an ANSI-256 index as a number, truecolor
 *  as "#rrggbb", "inv" for default-inverted; absent = the default color. `st` is
 *  a style bitmask (1 bold, 2 underline, 4 blink, 8 inverse, 16 invisible,
 *  32 dim, 64 italic, 128 strikethrough); absent = plain. */
export interface ScreenSegment {
  text: string;
  fg?: number | string;
  bg?: number | string;
  st?: number;
}

/** One row of a `screen` frame: its index in the visible grid (0 = top) and its
 *  segments. Empty `segs` = a blank row. */
export interface ScreenRowUpdate {
  row: number;
  segs: ScreenSegment[];
}

/** A frame of the rendered-screen stream. `reset: true` carries the full grid
 *  (sent first after `subscribeScreen` and again on a geometry / alt-screen
 *  flip); `reset: false` carries only the rows that changed since the last
 *  frame, coalesced server-side on an ~80ms tick. */
export interface ScreenFrame {
  sessionId: string;
  reset: boolean;
  cols: number;
  rows: number;
  cursorX: number;
  cursorY: number;
  cursorVisible: boolean;
  alt: boolean;
  lines: ScreenRowUpdate[];
}

/** Parse a raw WS message object into a ScreenFrame, or null if it isn't one.
 *  Lenient like the rest of this module: malformed frames are dropped, not thrown. */
export function parseScreenFrame(msg: Record<string, unknown>): ScreenFrame | null {
  if (msg.type !== "screen") return null;
  if (typeof msg.sessionId !== "string" || !msg.sessionId) return null;
  if (typeof msg.cols !== "number" || typeof msg.rows !== "number") return null;
  if (!Array.isArray(msg.lines)) return null;
  const lines: ScreenRowUpdate[] = [];
  for (const l of msg.lines as unknown[]) {
    if (typeof l !== "object" || l === null) return null;
    const row = (l as Record<string, unknown>).row;
    const segs = (l as Record<string, unknown>).segs;
    if (typeof row !== "number" || !Array.isArray(segs)) return null;
    lines.push({ row, segs: segs as ScreenSegment[] });
  }
  return {
    sessionId: msg.sessionId,
    reset: msg.reset === true,
    cols: msg.cols,
    rows: msg.rows,
    cursorX: typeof msg.cursorX === "number" ? msg.cursorX : 0,
    cursorY: typeof msg.cursorY === "number" ? msg.cursorY : 0,
    cursorVisible: msg.cursorVisible !== false,
    alt: msg.alt === true,
    lines,
  };
}

/** Client-side reconstruction of a session's screen from `screen` frames: apply a
 *  full snapshot on `reset`, patch listed rows otherwise. Rendering (2kz.3) reads
 *  `line()`/`lineText()`; `text()` gives the whole screen as plain text. */
export class ScreenMirror {
  cols = 0;
  rows = 0;
  cursorX = 0;
  cursorY = 0;
  cursorVisible = true;
  alt = false;
  private grid: ScreenSegment[][] = [];

  apply(frame: ScreenFrame): void {
    if (frame.reset || frame.rows !== this.rows || frame.cols !== this.cols) {
      this.grid = Array.from({ length: frame.rows }, () => []);
    }
    this.cols = frame.cols;
    this.rows = frame.rows;
    this.cursorX = frame.cursorX;
    this.cursorY = frame.cursorY;
    this.cursorVisible = frame.cursorVisible;
    this.alt = frame.alt;
    for (const line of frame.lines) {
      if (line.row >= 0 && line.row < this.grid.length) this.grid[line.row] = line.segs;
    }
  }

  line(row: number): ScreenSegment[] {
    return this.grid[row] ?? [];
  }

  lineText(row: number): string {
    return this.line(row)
      .map((s) => s.text)
      .join("");
  }

  /** The visible screen as text, trailing blank rows dropped. */
  text(): string {
    const rows: string[] = [];
    for (let r = 0; r < this.grid.length; r++) rows.push(this.lineText(r));
    let end = rows.length;
    while (end > 0 && rows[end - 1] === "") end -= 1;
    return rows.slice(0, end).join("\n");
  }
}

type ScreenListener = (frame: ScreenFrame) => void;
const screenListeners = new Map<string, ScreenListener[]>();

/** Subscribe to a session's rendered-screen stream over the shared native WS.
 *  Sends `subscribeScreen` on first listener (and again on every reconnect, so a
 *  fresh snapshot arrives), `unsubscribeScreen` when the last listener leaves.
 *  Returns an unsubscribe function. Listener errors are isolated. */
export function onSessionScreen(sessionId: string, listener: ScreenListener): () => void {
  const list = screenListeners.get(sessionId) ?? [];
  list.push(listener);
  screenListeners.set(sessionId, list);
  if (list.length === 1) sendToNative({ type: "subscribeScreen", sessionId });
  return () => {
    const cur = screenListeners.get(sessionId);
    if (!cur) return;
    const idx = cur.indexOf(listener);
    if (idx >= 0) cur.splice(idx, 1);
    if (cur.length === 0) {
      screenListeners.delete(sessionId);
      sendToNative({ type: "unsubscribeScreen", sessionId });
    }
  };
}

function emitScreenFrame(frame: ScreenFrame): void {
  for (const listener of screenListeners.get(frame.sessionId) ?? []) {
    try {
      listener(frame);
    } catch (e) {
      console.warn("oracle-mcp screen listener failed:", e instanceof Error ? e.message : e);
    }
  }
}

// ── Global pause (juancode-tnxx) ─────────────────────────────────────────────
// The phone's half of the desktop's pause button. The native endpoint owns the
// paused set and publishes it as `pauseState` — once right after `serverInfo`, and
// again on every change whichever surface made it — so this module never keeps a
// tally of its own, it just mirrors the last frame it was sent.

/** Capabilities the connected endpoint advertised, from its `serverInfo`. Empty
 *  until the handshake lands (and again after a disconnect), so a caller that
 *  feature-detects on it fails closed. */
let nativeCapabilities: string[] = [];

/** The set the endpoint says a play would revive right now. Null means we have not
 *  been told yet — distinct from an empty set, which means "no pause is in effect". */
let pausedSessionIds: string[] | null = null;

type PauseListener = (paused: string[]) => void;
const pauseListeners: PauseListener[] = [];

/** Whether this endpoint can pause and play everything at once. False on a core
 *  with no such frame, and false before the handshake — the caller should say so
 *  rather than send a frame into the dark. */
export function supportsGlobalPause(): boolean {
  return nativeCapabilities.includes("globalPause");
}

/** The sessions a play would revive, or null before the endpoint has said. */
export function pausedSessions(): string[] | null {
  return pausedSessionIds;
}

/** Watch the paused set. Fires on every `pauseState`, including the snapshot that
 *  lands on connect. Listener errors are isolated. */
export function onPauseState(listener: PauseListener): void {
  pauseListeners.push(listener);
}

/** Sleep every live agent session on the endpoint. Fire-and-forget: the answer is
 *  the `pauseState` frame that follows, not a reply to this. Returns false when the
 *  endpoint cannot serve it, so a caller can say why nothing happened. */
export function pauseAllSessions(): boolean {
  if (!supportsGlobalPause()) return false;
  sendToNative({ type: "pauseAll" });
  return true;
}

/** Revive exactly the set the last pause recorded. Same fire-and-forget shape. */
export function resumeAllSessions(): boolean {
  if (!supportsGlobalPause()) return false;
  sendToNative({ type: "resumeAll" });
  return true;
}

/** Parse a `pauseState` frame into its id list, or null if it is not one. Lenient
 *  like the rest of this module: a malformed frame is dropped, not thrown. */
export function parsePauseState(msg: Record<string, unknown>): string[] | null {
  if (msg.type !== "pauseState") return null;
  if (!Array.isArray(msg.paused)) return null;
  return msg.paused.filter((id): id is string => typeof id === "string");
}

function emitPauseState(paused: string[]): void {
  pausedSessionIds = paused;
  for (const listener of pauseListeners) {
    try {
      listener(paused);
    } catch (e) {
      console.warn("oracle-mcp pause listener failed:", e instanceof Error ? e.message : e);
    }
  }
}

// ── Named control keys (juancode-uigs) ───────────────────────────────────────
// The client→server mirror of `ClientMessage.key` in WireProtocol.swift:
//
//   { type: "key", sessionId: string, keys: string[], seq?: number }
//
// `keys` are NAMES ("Escape", "C-c", "Up"), never bytes: the vocabulary and its
// resolution belong to the core, so a client cannot invent an escape sequence and the
// two cores cannot disagree about one. The resolved bytes reach the pty raw — a `key`
// is never bracketed-pasted, which is what `input` does and what made every remote
// keystroke arrive as literal text. An unknown name is answered with `error` and
// writes nothing. Gated by the `namedKeys` capability.
//
// The sending itself lives in oracle.ts (`sendKeys`), on a short-lived socket like the
// other one-shot writes — so it feature-detects on that socket's own handshake rather
// than on this module's cached capability list, and works while this one is between
// reconnects. The table of names is keys.ts.
//
// ── Working-tree changes, capability `changes` (juancode-52e8.14.5) ──────────
//
// Deliberately NOT mirrored in this module, and the reason is worth writing down so
// the next person does not "fix" it. The `changes` surface is split by transport:
//
//   * The READS are HTTP — `GET /api/sessions/:id/{diff,git,worktrees,file}` — and
//     their client is session-reads.ts, beside the transcript and screen reads it
//     already owns. Nothing about them belongs on this socket.
//   * The WRITES are frames — `sessionCommit`, `sessionPush`, `sessionRevert`,
//     `sessionCommitMessage`, each answered by one `changesResult` correlated on
//     `requestId`. The sidecar does not send them: the phone console has no Commit,
//     Push or Discard, and mirroring frames nothing sends would be a second copy of
//     the protocol to keep in step for no caller. The desktop relay translates the
//     phone's POSTs into them (`CoreProxyServer.gitWrite`), so the HTTP shape the
//     Swift core served is still what a remote client sees.
//
// If a Changes view is ever built on the phone, its writes go through the relay's
// POSTs, not through here.
//
// ── The GitHub surface (juancode-52e8.14.6) ──────────────────────────────────
// The GitHub data layer lives in the core, so the phone reads a PR list, a
// conversation, a merged timeline and a parsed failing-CI log the same way the desktop
// does: over the core's own HTTP routes, through the relay on :4280. Those are plain
// requests and are made where they are needed (oracle.ts, the phone console) rather
// than mirrored here — nothing about them is a stream.
//
// What DOES belong on the socket is the review surface, because a refresh is a whole
// model turn: held open as a request it would block for minutes. Two client frames
// stage and unstage an inline comment, one asks for the review, and the core answers
// with `review` and `diffComments`. Both answers are ALWAYS complete — a whole comment
// list, never a delta, because two surfaces stage against one session — so a listener
// replaces what it holds rather than patching it.
//
// Gated by the `github` capability: the Swift core advertises none of this and the
// frames would be `error` there.

/** One review finding, anchored to the file and line it concerns. */
export interface ReviewFinding {
  file: string;
  /** `old` or `new` — which side of the hunk the line is on. */
  side: string;
  /** Absent for a file-level finding with no single line. */
  line?: number;
  severity: "critical" | "high" | "medium" | "low" | "info";
  title: string;
  note: string;
}

/** One cached review pass. `error` is present when the pass could not run or its
 *  output could not be read — cached like any other result, because "the last pass
 *  failed, and this is why" is an answer and losing it looks like no review at all. */
export interface ReviewPass {
  status: "ok" | "empty" | "error";
  findings: ReviewFinding[];
  summary?: string;
  createdAt: number;
  error?: string;
}

/** One inline comment staged against a session's diff. */
export interface DiffComment {
  id: string;
  sessionId: string;
  file: string;
  side: string;
  line: number;
  endLine: number;
  body: string;
  createdAt: number;
  quote?: string;
  commitSha?: string;
  commitSubject?: string;
}

/** Whether the connected core has the GitHub data layer at all. */
export function supportsGithub(): boolean {
  return nativeCapabilities.includes("github");
}

type ReviewListener = (sessionId: string, pass: ReviewPass | null) => void;
type CommentsListener = (sessionId: string, comments: DiffComment[]) => void;
const reviewListeners = new Set<ReviewListener>();
const commentListeners = new Set<CommentsListener>();

/** Watch review passes. Fires on every `review` frame; `null` is a session nothing has
 *  reviewed, which is not the same as a pass that found nothing. */
export function onReview(listener: ReviewListener): () => void {
  reviewListeners.add(listener);
  return () => reviewListeners.delete(listener);
}

/** Watch staged diff comments. Always the whole list; replace wholesale. */
export function onDiffComments(listener: CommentsListener): () => void {
  commentListeners.add(listener);
  return () => commentListeners.delete(listener);
}

/** Ask for a session's review — the cached one, or a fresh pass with `refresh`. */
export function requestReview(sessionId: string, refresh = false): void {
  sendToNative({ type: "sessionReview", sessionId, refresh });
}

/** A `review` frame, or null if it is not one. `result` absent and `result: null` say
 *  the same thing, and both spellings reach here. */
function parseReview(msg: Record<string, unknown>): { sessionId: string; pass: ReviewPass | null } | null {
  if (msg.type !== "review" || typeof msg.sessionId !== "string") return null;
  const raw = msg.result;
  if (raw === undefined || raw === null) return { sessionId: msg.sessionId, pass: null };
  if (typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const status = r.status;
  if (status !== "ok" && status !== "empty" && status !== "error") return null;
  return {
    sessionId: msg.sessionId,
    pass: {
      status,
      findings: Array.isArray(r.findings) ? (r.findings as ReviewFinding[]) : [],
      summary: typeof r.summary === "string" ? r.summary : undefined,
      createdAt: typeof r.createdAt === "number" ? r.createdAt : 0,
      error: typeof r.error === "string" ? r.error : undefined,
    },
  };
}

/** A `diffComments` frame, or null if it is not one. */
function parseDiffComments(
  msg: Record<string, unknown>,
): { sessionId: string; comments: DiffComment[] } | null {
  if (msg.type !== "diffComments" || typeof msg.sessionId !== "string") return null;
  if (!Array.isArray(msg.comments)) return null;
  return { sessionId: msg.sessionId, comments: msg.comments as DiffComment[] };
}

// ── Heavy command queue (juancode-52e8.14.3) ─────────────────────────────────
// The phone's view of the global `heavy` slot queue: memory-heavy commands (CI,
// integration tests) serialized across every agent session on the Mac. The CORE
// owns the shared registry and pushes the whole queue on every change, so this
// module never reads a directory — it mirrors the last `heavyQueue` frame, and the
// subscription is what tells the core somebody is looking.

/** One job in the queue. `child` and `started` are absent while a job waits. */
export interface HeavyJob {
  /** The wrapper's pid: the registry filename, and the id a cancel names. */
  pid: number;
  child?: number;
  /** Higher runs sooner; ties break on how long the job has been queued. */
  prio: number;
  /** Epoch seconds when it joined the queue. */
  since: number;
  started?: number;
  /** Slot index it holds, or 0 while waiting. */
  slot: number;
  cmd: string;
  cwd: string;
}

/** The whole queue: capacity, and the two lists already ordered by the core. */
export interface HeavyQueue {
  slots: number;
  workerCap: number;
  running: HeavyJob[];
  waiting: HeavyJob[];
}

/** The queue as the endpoint last sent it, or null before it has said. Distinct
 *  from an empty queue, which means nothing is running and nothing is waiting. */
let heavyQueueState: HeavyQueue | null = null;
/** Whether `heavyQueueSubscribe` has gone out on THIS socket. Per connection on the
 *  core's side, so a reconnect has to send it again. */
let heavySubscribed = false;

type HeavyListener = (queue: HeavyQueue) => void;
const heavyListeners: HeavyListener[] = [];

/** Whether the connected endpoint reads the slot registry. False before the
 *  handshake, so a caller fails closed rather than sending into the dark. */
export function supportsHeavyQueue(): boolean {
  return nativeCapabilities.includes("heavyQueue");
}

/** Ask the core to start pushing the queue. Idempotent per connection, and a no-op
 *  on an endpoint with no such frame. */
export function subscribeHeavyQueue(): boolean {
  if (!supportsHeavyQueue()) return false;
  if (heavySubscribed) return true;
  heavySubscribed = true;
  sendToNative({ type: "heavyQueueSubscribe" });
  return true;
}

/** The queue the endpoint last sent, or null before it has sent one. */
export function heavyQueue(): HeavyQueue | null {
  return heavyQueueState;
}

/** Watch the queue. Fires on every `heavyQueue` frame, which is always the complete
 *  queue — replace wholesale. Listener errors are isolated. */
export function onHeavyQueue(listener: HeavyListener): void {
  heavyListeners.push(listener);
}

/** Move a job in line. Fire-and-forget: the answer is the queue frame that follows.
 *  Higher priority runs sooner. */
export function heavySetPriority(pid: number, prio: number): boolean {
  if (!supportsHeavyQueue()) return false;
  sendToNative({ type: "heavySetPriority", pid, prio });
  return true;
}

/** How many heavy jobs may run at once. Raising it lets jobs already in line
 *  through, because the waiting wrappers re-read the capacity every poll. */
export function heavySetSlots(slots: number): boolean {
  if (!supportsHeavyQueue()) return false;
  sendToNative({ type: "heavySetSlots", slots });
  return true;
}

/** Stop a queued or running job. The core refuses a pid its own queue does not
 *  hold, so this can only reach a job in the list above. */
export function heavyCancel(pid: number): boolean {
  if (!supportsHeavyQueue()) return false;
  sendToNative({ type: "heavyCancel", pid });
  return true;
}

/** The priority that puts a job at the head of the line: one better than the best
 *  currently queued. The core's only mutation is a priority write, so this is what
 *  turns "run this next" into a number. */
export function heavyMoveToFrontPriority(queue: HeavyQueue): number {
  return Math.max(...queue.waiting.map((j) => j.prio), 0) + 1;
}

/** Parse a `heavyQueue` frame, or null if it is not one. Lenient like the rest of
 *  this module: a malformed frame is dropped, never thrown. */
export function parseHeavyQueue(msg: Record<string, unknown>): HeavyQueue | null {
  if (msg.type !== "heavyQueue") return null;
  if (typeof msg.slots !== "number") return null;
  return {
    slots: msg.slots,
    workerCap: typeof msg.workerCap === "number" ? msg.workerCap : 4,
    running: parseHeavyJobs(msg.running),
    waiting: parseHeavyJobs(msg.waiting),
  };
}

function parseHeavyJobs(raw: unknown): HeavyJob[] {
  if (!Array.isArray(raw)) return [];
  const jobs: HeavyJob[] = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") continue;
    const row = entry as Record<string, unknown>;
    if (typeof row.pid !== "number") continue;
    const job: HeavyJob = {
      pid: row.pid,
      prio: typeof row.prio === "number" ? row.prio : 0,
      since: typeof row.since === "number" ? row.since : 0,
      slot: typeof row.slot === "number" ? row.slot : 0,
      cmd: typeof row.cmd === "string" ? row.cmd : "",
      cwd: typeof row.cwd === "string" ? row.cwd : "",
    };
    if (typeof row.child === "number") job.child = row.child;
    if (typeof row.started === "number") job.started = row.started;
    jobs.push(job);
  }
  return jobs;
}

function emitHeavyQueue(queue: HeavyQueue): void {
  heavyQueueState = queue;
  for (const listener of heavyListeners) {
    try {
      listener(queue);
    } catch (e) {
      console.warn("oracle-mcp heavy listener failed:", e instanceof Error ? e.message : e);
    }
  }
}

function sendToNative(msg: Record<string, unknown>): void {
  if (ws?.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify(msg));
    } catch {
      // Reconnect re-subscribes; a failed send is recovered there.
    }
  }
}

// ── WS client: native backend → subscribers ──────────────────────────────────

let ws: WebSocket | null = null;
let reconnectMs = 1000;
const MAX_RECONNECT_MS = 30_000;
let stopped = false;

/** Open (and keep open, with backoff) a client WS to the native server and fan
 *  out session activity to subscribers. Safe to call once at startup. */
export function startActivityListener(): void {
  stopped = false;
  connect();
}

export function stopActivityListener(): void {
  stopped = true;
  ws?.close();
  ws = null;
}

function connect(): void {
  if (stopped) return;
  const sock = new WebSocket(nativeWsUrl());
  ws = sock;

  sock.on("open", () => {
    reconnectMs = 1000;
    // Re-assert screen subscriptions: the server replies to each with a fresh
    // full snapshot, so viewers render the correct screen after a reconnect.
    for (const sessionId of screenListeners.keys()) {
      sendToNative({ type: "subscribeScreen", sessionId });
    }
    // And the heavy queue, for the same reason: the watch is per connection on the
    // core's side, so a reconnect has to ask again or the queue silently stops
    // updating. Only when something is actually watching.
    if (heavyListeners.length > 0) subscribeHeavyQueue();
  });

  sock.on("message", (data) => {
    handleMessage(data.toString());
  });

  sock.on("close", () => {
    if (ws === sock) ws = null;
    // Fail closed until the next handshake: an endpoint that went away is not one
    // whose capabilities or paused set we still know.
    nativeCapabilities = [];
    pausedSessionIds = null;
    // Dropped rather than kept: jobs have started and finished while this socket was
    // down, and a stale queue is worse than none — it is what a reorder would be
    // computed against.
    heavyQueueState = null;
    heavySubscribed = false;
    scheduleReconnect();
  });

  sock.on("error", () => {
    // 'close' fires after 'error'; let scheduleReconnect run there.
    sock.close();
  });
}

function scheduleReconnect(): void {
  if (stopped) return;
  const delay = reconnectMs;
  reconnectMs = Math.min(reconnectMs * 2, MAX_RECONNECT_MS);
  setTimeout(connect, delay);
}

function handleMessage(raw: string): void {
  let msg: Record<string, unknown>;
  try {
    msg = JSON.parse(raw);
  } catch {
    return;
  }
  if (msg.type === "serverInfo") {
    nativeCapabilities = Array.isArray(msg.capabilities)
      ? msg.capabilities.filter((c): c is string => typeof c === "string")
      : [];
    return;
  }
  if (msg.type === "pauseState") {
    const paused = parsePauseState(msg);
    if (paused) emitPauseState(paused);
    return;
  }
  if (msg.type === "heavyQueue") {
    const queue = parseHeavyQueue(msg);
    if (queue) emitHeavyQueue(queue);
    return;
  }
  if (msg.type === "review") {
    const ev = parseReview(msg);
    if (ev) for (const l of reviewListeners) l(ev.sessionId, ev.pass);
    return;
  }
  if (msg.type === "diffComments") {
    const ev = parseDiffComments(msg);
    if (ev) for (const l of commentListeners) l(ev.sessionId, ev.comments);
    return;
  }
  if (msg.type === "screen") {
    const frame = parseScreenFrame(msg);
    if (frame) emitScreenFrame(frame);
    return;
  }
  if (msg.type === "stuck") {
    const ev = parseStuckEvent(msg);
    if (ev) emitStuckEvent(ev);
    return;
  }
  if (msg.type === "sessionMeta") {
    const sample = parseUsageSample(msg);
    if (sample) emitUsageSample(sample);
    return;
  }
  if (msg.type !== "activity") return;
  const state = typeof msg.state === "string" ? msg.state : "";
  const sessionId = typeof msg.sessionId === "string" ? msg.sessionId : "";
  if (sessionId && (state === "busy" || state === "idle" || state === "waiting_input")) {
    const ev: SessionActivityEvent = { sessionId, state, notify: msg.notify === true };
    const changes = parseChanges(msg.changes);
    if (changes) ev.changes = changes;
    if (typeof msg.dispatchId === "string" && msg.dispatchId) ev.dispatchId = msg.dispatchId;
    emitSessionEvent(ev);
  }
}

/** Parse the optional `changes` rollup off an activity broadcast; lenient like
 *  the rest of this module — a malformed rollup is dropped, never thrown. */
function parseChanges(raw: unknown): SessionChanges | null {
  if (!raw || typeof raw !== "object") return null;
  const { files, additions, deletions } = raw as Record<string, unknown>;
  if (typeof files !== "number" || typeof additions !== "number" || typeof deletions !== "number") {
    return null;
  }
  return { files, additions, deletions };
}
