// The conformance client: one WebSocket to the core under test, every frame
// recorded in arrival order.
//
// Same client shape the Oracle sidecar uses (`apps/oracle-mcp/src/native-events.ts`):
// the `ws` package, JSON text frames, lenient parsing. The difference is that
// nothing here is lenient about ORDER — a transcript is asserted against the
// recorded stream with a cursor, so "created before attached" is a real assertion
// rather than a hope.

import { WebSocket } from "ws";

import { matchValue, type MatchResult, type Vars } from "./match.ts";

export type Frame = Record<string, unknown>;

export interface WaitOptions {
  vars?: Vars;
  timeoutMs?: number;
  /** Frame types this assertion does not constrain. "*" tolerates anything. */
  ignore?: string[];
}

export class WireProtocolError extends Error {}

/** Which sessions the scenario driving this connection is asserting about.
 *
 *  A connection is told about EVERY session the core has, not only the ones the
 *  scenario created: the next scenario's socket is the one open when the previous
 *  scenario's killed pty is finally reaped, so its `exit` lands mid-assertion and
 *  fails a step about a session the scenario has never heard of (juancode-a3ck).
 *  A scenario asserts about ITS sessions; a frame about somebody else's is noise
 *  by definition, and the driver is the only thing that knows which is which. */
export interface SessionScope {
  /** Record the session ids a frame announces as this scenario's own. Called for
   *  every frame as it arrives, so ownership is known before anything matches. */
  claim(frame: Frame): void;
  /** True when a frame is about a session a DIFFERENT scenario created. */
  isForeign(frame: Frame): boolean;
}

export interface ConnectOptions {
  timeoutMs?: number;
  /** Ownership filter; without one, every frame is this connection's business. */
  scope?: SessionScope;
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export class WireClient {
  readonly name: string;
  readonly url: string;
  readonly frames: Frame[] = [];
  /** Text frames that were not JSON at all — a core bug if it ever happens. */
  readonly undecodable: string[] = [];

  private socket: WebSocket;
  private cursor = 0;
  private closed = false;
  private scope?: SessionScope;

  private constructor(name: string, url: string, socket: WebSocket, scope?: SessionScope) {
    this.name = name;
    this.url = url;
    this.socket = socket;
    this.scope = scope;
    socket.on("message", (data) => {
      const text = data.toString();
      try {
        const frame = JSON.parse(text) as Frame;
        this.frames.push(frame);
        // At arrival, not at match time: a session is this scenario's from the
        // moment the core answers, so its later `exit` is never read as foreign.
        this.scope?.claim(frame);
      } catch {
        this.undecodable.push(text);
      }
    });
    socket.on("close", () => {
      this.closed = true;
    });
  }

  static async connect(url: string, name = "a", opts: ConnectOptions = {}): Promise<WireClient> {
    const { timeoutMs = 10_000, scope } = opts;
    const socket = new WebSocket(url);
    const client = new WireClient(name, url, socket, scope);
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`connect to ${url} timed out`)), timeoutMs);
      socket.once("open", () => {
        clearTimeout(timer);
        resolve();
      });
      socket.once("error", (e) => {
        clearTimeout(timer);
        reject(e);
      });
    });
    return client;
  }

  get isClosed(): boolean {
    return this.closed;
  }

  send(msg: Frame): void {
    this.socket.send(JSON.stringify(msg));
  }

  /** Send a raw text frame — how the malformed-JSON rule gets tested. */
  sendRaw(text: string): void {
    this.socket.send(text);
  }

  /** True when this frame is about a session some other scenario created. */
  private isForeign(frame: Frame): boolean {
    return this.scope?.isForeign(frame) ?? false;
  }

  /** The frame at an absolute index (0 = the first frame the core ever sent),
   *  counting only frames this scenario owns. "serverInfo is frame 0" is an
   *  assertion about what this connection is told in reply to its own arrival; a
   *  broadcast about a session another scenario is still reaping does not move it. */
  frameAt(index: number): Frame | undefined {
    return this.frames.filter((f) => !this.isForeign(f))[index];
  }

  /** Advance the cursor past everything already received (used between phases). */
  drain(): void {
    this.cursor = this.frames.length;
  }

  /** The handshake frame, plus anything that arrived before it.
   *
   *  Deliberately NOT "frame 0": the Swift core starts its activity fan-out before
   *  it queues `serverInfo`, so a connection opened while other sessions are live
   *  sees `activity` first. What the wire actually guarantees — and what a client
   *  can rely on — is that no REPLY precedes the handshake. */
  async handshake(timeoutMs = 10_000): Promise<{ frame: Frame; before: Frame[] }> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const index = this.frames.findIndex((f) => f.type === "serverInfo");
      if (index >= 0) {
        const before = this.frames.slice(0, index);
        const early = before.find(
          (f) => SOLICITED_TYPES.includes(String(f.type)) && !this.isForeign(f),
        );
        if (early) {
          throw new WireProtocolError(
            `[${this.name}] ${String(early.type)} arrived before the serverInfo handshake`,
          );
        }
        return { frame: this.frames[index] as Frame, before };
      }
      if (Date.now() > deadline) {
        throw new WireProtocolError(
          `[${this.name}] no serverInfo within ${timeoutMs}ms (frames: ` +
            `${this.frames.map((f) => String(f.type)).join(", ") || "none"})`,
        );
      }
      await sleep(10);
    }
  }

  /** Consume frames until one matches, failing on any non-ignored frame in between.
   *  The cursor advances past the match, so consecutive waits assert ordering. */
  async waitFor(matcher: Frame, opts: WaitOptions = {}): Promise<Frame> {
    const { vars = {}, timeoutMs = 8_000, ignore = [] } = opts;
    const deadline = Date.now() + timeoutMs;
    const skipAll = ignore.includes("*");
    for (;;) {
      while (this.cursor < this.frames.length) {
        const frame = this.frames[this.cursor] as Frame;
        this.cursor += 1;
        // Before matching, not after: an earlier scenario's late `exit` is neither
        // a verdict on this step nor allowed to satisfy it, and a matcher that
        // names no session (`{ "type": "exit" }`) would otherwise accept it.
        if (this.isForeign(frame)) continue;
        const result = matchValue(frame, matcher, vars);
        if (result.ok) return frame;
        const type = typeof frame.type === "string" ? frame.type : "<untyped>";
        if (skipAll || ignore.includes(type)) continue;
        throw new WireProtocolError(
          `[${this.name}] unexpected frame before ${describe(matcher)}\n` +
            `  got: ${JSON.stringify(frame).slice(0, 400)}\n` +
            `  mismatch: ${result.why}`,
        );
      }
      if (Date.now() > deadline) {
        throw new WireProtocolError(
          `[${this.name}] timed out after ${timeoutMs}ms waiting for ${describe(matcher)}\n` +
            `  frames seen: ${this.frames.map((f) => String(f.type)).join(", ") || "none"}`,
        );
      }
      if (this.closed) {
        throw new WireProtocolError(
          `[${this.name}] socket closed while waiting for ${describe(matcher)}`,
        );
      }
      await sleep(10);
    }
  }

  /** Assert nothing matching arrives within a window. Non-matching frames are
   *  consumed, so a negative assertion never swallows the next positive one. */
  async expectNone(matcher: Frame, opts: WaitOptions & { withinMs?: number } = {}): Promise<void> {
    const { vars = {}, withinMs = 600 } = opts;
    const deadline = Date.now() + withinMs;
    for (;;) {
      while (this.cursor < this.frames.length) {
        const frame = this.frames[this.cursor] as Frame;
        // A negative assertion must not be satisfied-or-broken by another
        // scenario's session either: "no exit for MY session" is the claim.
        if (this.isForeign(frame)) {
          this.cursor += 1;
          continue;
        }
        const result = matchValue(frame, matcher, vars);
        if (result.ok) {
          throw new WireProtocolError(
            `[${this.name}] expected NO frame matching ${describe(matcher)}, got ` +
              JSON.stringify(frame).slice(0, 400),
          );
        }
        this.cursor += 1;
      }
      if (Date.now() > deadline) return;
      await sleep(10);
    }
  }

  close(): void {
    this.closed = true;
    try {
      this.socket.close();
    } catch {
      // Already gone; nothing to do.
    }
  }
}

function describe(matcher: Frame): string {
  const type = typeof matcher.type === "string" ? matcher.type : "?";
  const rest = Object.entries(matcher).filter(([k]) => k !== "type");
  return rest.length ? `${type} ${JSON.stringify(Object.fromEntries(rest))}` : type;
}

/** Frames that only ever exist as a reply to something the client sent. None of
 *  these may precede the handshake: a client must know the version and capability
 *  list before it can interpret an answer. Unsolicited broadcasts (`activity` for
 *  sessions that already existed) are a different case — see SERVER_INFO_ORDERING
 *  in the spec rules. */
export const SOLICITED_TYPES = [
  "created",
  "attached",
  "output",
  "screen",
  "inputAck",
  "resizeAck",
  "exit",
  "queue",
  "editorReady",
  "terminalReady",
  "unresumable",
  "error",
  "trackedPrs",
];

/** Convenience for the negotiation tests: the handshake, as a typed value. */
export interface ServerInfo {
  protocolVersion: number;
  capabilities: string[];
  /** This connection's grid-ownership token, when the core reports one. Absent on
   *  a core without the `gridOwner` capability, where owners are never named. */
  clientId?: string;
}

export function readServerInfo(frame: Frame | undefined): ServerInfo {
  const result: MatchResult = matchValue(frame, {
    type: "serverInfo",
    protocolVersion: { $type: "number" },
    capabilities: { $type: "array" },
  });
  if (!result.ok) {
    throw new WireProtocolError(`not a valid serverInfo frame: ${result.why}`);
  }
  const f = frame as Frame;
  return {
    protocolVersion: f.protocolVersion as number,
    capabilities: f.capabilities as string[],
    clientId: typeof f.clientId === "string" ? f.clientId : undefined,
  };
}
