// Oracle MCP sidecar (juancode-nsr). A small stateless Streamable-HTTP MCP server
// that fronts the local Oracle control surface so a remote client — e.g. the
// Claude mobile app's custom connector, reached through a Cloudflare Tunnel +
// Access — can see global issues, dispatch agents into projects, list running
// sessions, and ask the Oracle. The pty/agent work still happens on the Mac; this
// only relays intent (file mailboxes) and reads (bd + the native app's HTTP API).
//
// Auth is intentionally NOT handled here: Cloudflare Access sits in front and only
// forwards already-authenticated requests, so the sidecar binds to localhost and
// trusts its caller. Never expose this port directly to the internet.

import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { loadEnvFile } from "./load-env.ts";

// Seed config (e.g. TELEGRAM_BOT_TOKEN / ALLOWED_USER_IDS) from apps/oracle-mcp/.env
// when not already exported by the launching shell. Must run before anything reads
// process.env below. A real shell export always wins; a missing file is a no-op.
const loaded = loadEnvFile(join(dirname(fileURLToPath(import.meta.url)), "..", ".env"));
if (loaded.length) console.log(`oracle-mcp: loaded ${loaded.length} var(s) from .env`);
import express, { type Request, type Response } from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import {
  appendAsk,
  appendDispatch,
  createIssue,
  deleteSession,
  deliverReply,
  queueMessages,
  listIssues,
  listSessions,
  oracleChat,
  oracleChatStream,
  resetChat,
} from "./oracle.ts";
import { listChatSessions, removeChatSession } from "./chat-store.ts";
import {
  observeSessionForOracle,
  unobserveSessionForOracle,
  outcomeLabel,
  type ObserveOutcome,
} from "./observer-trigger.ts";
import { consoleHtml, iconPng, webManifest } from "./ui.ts";
import { startActivityListener } from "./native-events.ts";
import { startTelegramBridge } from "./telegram.ts";

type ToolResult = {
  content: { type: "text"; text: string }[];
  isError?: boolean;
};

/** Where phone-composer uploads land. The Oracle's `claude -p` runs on this same
 *  machine, so a temp-dir path is directly readable once inlined into the message. */
const UPLOAD_DIR = join(tmpdir(), "oracle-uploads");

/** Strip a client-supplied filename down to a safe, space-free basename. */
function safeUploadName(raw: string): string {
  const base = raw.split(/[\\/]/).pop() ?? "";
  const cleaned = base.replace(/[^A-Za-z0-9._-]/g, "_").replace(/^\.+/, "");
  return cleaned.slice(-128) || "file";
}

const ok = (text: string): ToolResult => ({ content: [{ type: "text", text }] });
const fail = (message: string): ToolResult => ({
  content: [{ type: "text", text: message }],
  isError: true,
});

/** Wrap a tool body so any thrown error becomes a clean `isError` result the model
 *  can read, rather than a transport-level failure. */
function tool(run: () => Promise<ToolResult>): () => Promise<ToolResult> {
  return async () => {
    try {
      return await run();
    } catch (e) {
      return fail(e instanceof Error ? e.message : String(e));
    }
  };
}

/** A fresh MCP server per request (stateless mode) with the Oracle tools bound. */
function buildServer(): McpServer {
  const server = new McpServer({ name: "juancode-oracle", version: "0.1.0" });

  server.registerTool(
    "oracle_list_issues",
    {
      title: "List Oracle global issues",
      description:
        "List the Oracle's GLOBAL bd tracker items (cross-project work). Returns id, title, status, priority, type, parent, and whether each is ready (unblocked).",
      inputSchema: {},
    },
    tool(async () => ok(JSON.stringify(await listIssues(), null, 2))),
  );

  server.registerTool(
    "oracle_create_issue",
    {
      title: "Create Oracle global issue",
      description:
        "Create a new item in the Oracle's GLOBAL tracker (for cross-project work). Reference per-project issue ids in the description rather than editing project trackers from here.",
      inputSchema: {
        title: z.string().min(1).describe("Short issue title"),
        description: z.string().optional().describe("Details / context for the issue"),
        type: z
          .enum(["bug", "feature", "task", "epic", "chore"])
          .optional()
          .describe("Issue type (default: task)"),
        priority: z
          .number()
          .int()
          .min(0)
          .max(4)
          .optional()
          .describe("0=critical … 4=backlog (default: 2)"),
      },
    },
    async (args) => {
      try {
        const { id } = await createIssue(args);
        return ok(id ? `Created ${id}: ${args.title}` : `Created issue: ${args.title}`);
      } catch (e) {
        return fail(e instanceof Error ? e.message : String(e));
      }
    },
  );

  server.registerTool(
    "oracle_dispatch",
    {
      title: "Dispatch an agent into a project",
      description:
        "Spawn (or seed) a real agent session in a project on the Mac by appending to the Oracle's dispatch mailbox. The native app must be running; it tails the mailbox and starts the session.",
      inputSchema: {
        project: z.string().min(1).describe("Absolute path of the target project / work dir"),
        prompt: z.string().min(1).describe("The seed instruction sent to the agent"),
        provider: z.enum(["claude", "codex"]).optional().describe("Default: claude"),
        worktree: z
          .boolean()
          .optional()
          .describe("Isolate the agent in a fresh git worktree (default: false)"),
      },
    },
    async (args) => {
      try {
        await appendDispatch(args);
        return ok(
          `Dispatched ${args.provider ?? "claude"} into ${args.project}${
            args.worktree ? " (worktree)" : ""
          }. Watch for it in the session list.`,
        );
      } catch (e) {
        return fail(e instanceof Error ? e.message : String(e));
      }
    },
  );

  server.registerTool(
    "oracle_list_sessions",
    {
      title: "List running sessions",
      description:
        "List the live + persisted agent sessions across all projects (id, title, cwd, provider, status), read from the native app's embedded server.",
      inputSchema: {},
    },
    tool(async () => ok(JSON.stringify(await listSessions(), null, 2))),
  );

  server.registerTool(
    "oracle_delete_session",
    {
      title: "Delete a session",
      description:
        "Permanently delete an agent session by id: kills its pty, drops it from the store, and removes any auto-created git worktree (best-effort). The native app must be running.",
      inputSchema: {
        id: z.string().min(1).describe("The session id to delete (from oracle_list_sessions)"),
      },
    },
    async (args) => {
      try {
        await deleteSession(args.id);
        return ok(`Deleted session ${args.id}.`);
      } catch (e) {
        return fail(e instanceof Error ? e.message : String(e));
      }
    },
  );

  server.registerTool(
    "oracle_ask",
    {
      title: "Ask the Oracle",
      description:
        "Send a question/instruction to the live Oracle agent on the Mac (it reasons about cross-project work and can dispatch). Delivered via the Oracle's ask mailbox; the app spawns the Oracle if it isn't running.",
      inputSchema: {
        text: z.string().min(1).describe("The question or instruction for the Oracle"),
      },
    },
    async (args) => {
      try {
        await appendAsk(args.text);
        return ok("Delivered to the Oracle. Its reply shows in the Oracle chat on the Mac.");
      } catch (e) {
        return fail(e instanceof Error ? e.message : String(e));
      }
    },
  );

  server.registerTool(
    "oracle_queue_messages",
    {
      title: "Queue messages to a session",
      description:
        "Queue one or more messages to a running agent session for in-order delivery. Unlike a direct reply, queued messages are held and released one at a time on the session's next idle, so they're delivered in order even while the agent is still busy. The native app must be running.",
      inputSchema: {
        sessionId: z
          .string()
          .min(1)
          .describe("The session id to queue to (from oracle_list_sessions)"),
        messages: z
          .array(z.string().min(1))
          .min(1)
          .describe("One or more messages, delivered in this order on each idle"),
      },
    },
    async (args) => {
      try {
        await queueMessages(args.sessionId, args.messages);
        const n = args.messages.length;
        return ok(`Queued ${n} message${n === 1 ? "" : "s"} to session ${args.sessionId}.`);
      } catch (e) {
        return fail(e instanceof Error ? e.message : String(e));
      }
    },
  );

  server.registerTool(
    "oracle_observe_session",
    {
      title: "Observe a session (Telegram alerts)",
      description:
        "Subscribe to a running session's genuine state transitions and get pinged on Telegram when it NEEDS YOUR INPUT or FINISHES (no mid-run spam). Use this when asked to 'observe', 'watch', 'subscribe to', or 'keep me posted on' a session. Fans out to every known Telegram chat (message the bot once, or set ALLOWED_USER_IDS, so it knows where to notify). Reply to the Telegram notification to answer straight into that session.",
      inputSchema: {
        sessionId: z
          .string()
          .min(1)
          .describe("The session id to observe (from oracle_list_sessions)"),
      },
    },
    async (args) => {
      try {
        return ok(observeMessage(await observeSessionForOracle(args.sessionId)));
      } catch (e) {
        return fail(e instanceof Error ? e.message : String(e));
      }
    },
  );

  server.registerTool(
    "oracle_unobserve_session",
    {
      title: "Stop observing a session",
      description:
        "Stop Telegram alerts for a session: unsubscribes every chat currently observing it. Use when asked to 'stop watching', 'unsubscribe from', or 'stop keeping me posted on' a session.",
      inputSchema: {
        sessionId: z
          .string()
          .min(1)
          .describe("The session id to stop observing (from oracle_list_sessions)"),
      },
    },
    async (args) => {
      try {
        return ok(unobserveMessage(await unobserveSessionForOracle(args.sessionId)));
      } catch (e) {
        return fail(e instanceof Error ? e.message : String(e));
      }
    },
  );

  return server;
}

/** Confirmation copy for an observe, shared by the MCP tool and POST /api/observe.
 *  Distinguishes an unknown id (native app reachable, no match) and a missing
 *  Telegram target (nothing to notify) so the user knows what to fix. */
function observeMessage(o: ObserveOutcome): string {
  if (o.reachable && !o.found) {
    return `No session with id ${o.sessionId}. Use oracle_list_sessions to find the right id.`;
  }
  const label = outcomeLabel(o);
  if (o.chatIds.length === 0) {
    return `Recorded an observer for ${label}, but no Telegram chat is set up yet — message the Oracle bot once (or set ALLOWED_USER_IDS) so it knows where to ping you.`;
  }
  const n = o.chatIds.length;
  const confirmed = o.reachable
    ? ""
    : " (native app unreachable — couldn't confirm the session, subscribed anyway)";
  return `Observing ${label}${confirmed}. ${n} Telegram chat${n === 1 ? "" : "s"} will be pinged when it needs input or finishes. Reply to that message to answer into the session.`;
}

/** Confirmation copy for an unobserve, shared by the MCP tool and POST /api/unobserve. */
function unobserveMessage(o: ObserveOutcome): string {
  const label = outcomeLabel(o);
  if (o.changed === 0) return `No one was observing ${label} — nothing to stop.`;
  return `Stopped observing ${label} (cleared ${o.changed} subscription${o.changed === 1 ? "" : "s"}).`;
}

const app = express();
app.use(express.json());

app.get("/healthz", (_req: Request, res: Response) => {
  res.json({ ok: true, service: "oracle-mcp" });
});

// ── Phone web console ────────────────────────────────────────────────────────
// A browser UI (served at `/`) + REST endpoints, for clients that can't use a
// custom MCP connector. Same surface as the MCP tools; auth is Cloudflare Access
// (browser cookie), same as `/mcp`.

app.get("/", (_req: Request, res: Response) => {
  res.type("html").send(consoleHtml);
});

const sendErr = (res: Response, e: unknown) =>
  res.status(500).send(e instanceof Error ? e.message : String(e));

app.get("/api/issues", async (_req: Request, res: Response) => {
  try {
    res.json(await listIssues());
  } catch (e) {
    sendErr(res, e);
  }
});

app.post("/api/issues", async (req: Request, res: Response) => {
  try {
    const { title, description, type, priority } = req.body ?? {};
    if (typeof title !== "string" || !title.trim()) {
      res.status(400).send("title is required");
      return;
    }
    res.json(await createIssue({ title, description, type, priority }));
  } catch (e) {
    sendErr(res, e);
  }
});

app.get("/api/sessions", async (_req: Request, res: Response) => {
  try {
    res.json(await listSessions());
  } catch (e) {
    sendErr(res, e);
  }
});

app.post("/api/sessions/delete", async (req: Request, res: Response) => {
  try {
    const id = (req.body ?? {}).id;
    if (typeof id !== "string" || !id) {
      res.status(400).send("id is required");
      return;
    }
    await deleteSession(id);
    res.json({ ok: true });
  } catch (e) {
    sendErr(res, e);
  }
});

app.post("/api/dispatch", async (req: Request, res: Response) => {
  try {
    const { project, prompt, provider, worktree } = req.body ?? {};
    if (typeof project !== "string" || typeof prompt !== "string" || !project || !prompt) {
      res.status(400).send("project and prompt are required");
      return;
    }
    await appendDispatch({ project, prompt, provider, worktree: worktree === true });
    res.json({ ok: true });
  } catch (e) {
    sendErr(res, e);
  }
});

app.post("/api/ask", async (req: Request, res: Response) => {
  try {
    const text = (req.body ?? {}).text;
    if (typeof text !== "string" || !text.trim()) {
      res.status(400).send("text is required");
      return;
    }
    await appendAsk(text);
    res.json({ ok: true });
  } catch (e) {
    sendErr(res, e);
  }
});

// Observe / unobserve a session for Telegram alerts (juancode-nez), so the phone
// console can toggle the same subscription the MCP tool / Telegram /observe do.
app.post("/api/observe", async (req: Request, res: Response) => {
  try {
    const sessionId = (req.body ?? {}).sessionId;
    if (typeof sessionId !== "string" || !sessionId) {
      res.status(400).send("sessionId is required");
      return;
    }
    const outcome = await observeSessionForOracle(sessionId);
    res.json({ ok: true, message: observeMessage(outcome), ...outcome });
  } catch (e) {
    sendErr(res, e);
  }
});

app.post("/api/unobserve", async (req: Request, res: Response) => {
  try {
    const sessionId = (req.body ?? {}).sessionId;
    if (typeof sessionId !== "string" || !sessionId) {
      res.status(400).send("sessionId is required");
      return;
    }
    const outcome = await unobserveSessionForOracle(sessionId);
    res.json({ ok: true, message: unobserveMessage(outcome), ...outcome });
  } catch (e) {
    sendErr(res, e);
  }
});

app.post("/api/chat", async (req: Request, res: Response) => {
  try {
    const { text, sessionId } = req.body ?? {};
    if (typeof text !== "string" || !text.trim()) {
      res.status(400).send("text is required");
      return;
    }
    res.json(await oracleChat(text, typeof sessionId === "string" ? sessionId : null));
  } catch (e) {
    sendErr(res, e);
  }
});

// Live chat over Server-Sent Events: the console POSTs here and reads the Oracle's
// reply as it streams (`event: delta`), then a terminal `event: done` carrying the
// (possibly new) session id. The console falls back to the blocking /api/chat above
// when SSE is unavailable (old browser, or a proxy that buffers the stream). Auth is
// the same Cloudflare Access cookie as every other route.
app.post("/api/chat/stream", async (req: Request, res: Response) => {
  const { text, sessionId } = req.body ?? {};
  if (typeof text !== "string" || !text.trim()) {
    res.status(400).send("text is required");
    return;
  }
  res.writeHead(200, {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    // Disable proxy buffering (nginx/cloudflared) so deltas reach the phone live.
    "X-Accel-Buffering": "no",
  });
  // An initial comment opens the stream promptly through intermediaries.
  res.write(": open\n\n");
  const sse = (event: string, data: unknown) => {
    res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  };
  // Abort the underlying `claude` child if the phone navigates away mid-turn.
  const ac = new AbortController();
  res.on("close", () => ac.abort());
  try {
    const done = await oracleChatStream(
      text,
      typeof sessionId === "string" ? sessionId : null,
      (chunk) => sse("delta", { text: chunk }),
      ac.signal,
    );
    sse("done", { sessionId: done.sessionId, isError: done.isError });
  } catch (e) {
    sse("error", { message: e instanceof Error ? e.message : String(e) });
  } finally {
    res.end();
  }
});

// Accept an image/audio file's raw bytes from the phone composer, persist them, and
// return the absolute path. The Oracle runs `claude -p` on this same Mac with
// --dangerously-skip-permissions, so a saved path inlined into the chat message is
// read by claude directly — mirrors apps/server's /api/uploads + the apps/web flow.
// `express.raw` handles any content type for this route only; the global json parser
// leaves non-json bodies untouched.
app.post("/api/uploads", express.raw({ type: () => true, limit: "100mb" }), (req, res) => {
  const body = req.body as Buffer;
  if (!Buffer.isBuffer(body) || body.length === 0) {
    res.status(400).json({ error: "empty upload" });
    return;
  }
  const name = safeUploadName(typeof req.query.name === "string" ? req.query.name : "");
  try {
    mkdirSync(UPLOAD_DIR, { recursive: true });
    const path = join(UPLOAD_DIR, `${randomUUID().slice(0, 8)}-${name}`);
    writeFileSync(path, body);
    res.json({ path });
  } catch (err) {
    res.status(500).json({ error: err instanceof Error ? err.message : String(err) });
  }
});

// Deliver a typed reply from the phone into a live session's pty (answers the
// agent's question / decision). Goes over the native server's WS `input`, so the
// native app must be running. See oracle.ts deliverReply for the submit framing.
app.post("/api/reply", async (req: Request, res: Response) => {
  try {
    const { sessionId, text } = req.body ?? {};
    if (typeof sessionId !== "string" || !sessionId) {
      res.status(400).send("sessionId is required");
      return;
    }
    if (typeof text !== "string" || !text.trim()) {
      res.status(400).send("text is required");
      return;
    }
    await deliverReply(sessionId, text);
    res.json({ ok: true });
  } catch (e) {
    sendErr(res, e);
  }
});

// Queue one or more messages to a live session for in-order delivery on its next
// idle (juancode-r82). Accepts `messages: string[]` (or a single `text`), handed to
// the native server's persisted per-session queue. The native app must be running.
app.post("/api/queue", async (req: Request, res: Response) => {
  try {
    const body = req.body ?? {};
    const sessionId = body.sessionId;
    if (typeof sessionId !== "string" || !sessionId) {
      res.status(400).send("sessionId is required");
      return;
    }
    const raw: unknown[] = Array.isArray(body.messages) ? body.messages : [body.text];
    const messages = raw.filter((m): m is string => typeof m === "string" && m.trim().length > 0);
    if (messages.length === 0) {
      res.status(400).send("messages (a non-empty string array) or text is required");
      return;
    }
    await queueMessages(sessionId, messages);
    res.json({ ok: true });
  } catch (e) {
    sendErr(res, e);
  }
});

// Past phone-chat sessions, so the console can list + continue any of them. Continuity
// is `claude --resume` under the hood; we persist only the session record, no transcript.
app.get("/api/chat/sessions", async (_req: Request, res: Response) => {
  try {
    res.json(await listChatSessions());
  } catch (e) {
    sendErr(res, e);
  }
});

app.post("/api/chat/sessions/delete", async (req: Request, res: Response) => {
  try {
    const id = (req.body ?? {}).id;
    if (typeof id !== "string" || !id) {
      res.status(400).send("id is required");
      return;
    }
    await removeChatSession(id);
    res.json({ ok: true });
  } catch (e) {
    sendErr(res, e);
  }
});

// Legacy: clears the pre-multi-session single-session pointer. The console now starts a
// fresh thread client-side (send with no sessionId) rather than calling this.
app.post("/api/chat/reset", async (_req: Request, res: Response) => {
  try {
    await resetChat();
    res.json({ ok: true });
  } catch (e) {
    sendErr(res, e);
  }
});

// ── PWA install assets ───────────────────────────────────────────────────────
// The phone console can be added to the home screen and launched standalone.
// Notifications are handled over Telegram — no service worker or Web Push here.

app.get("/manifest.webmanifest", (_req: Request, res: Response) => {
  res.type("application/manifest+json").json(webManifest);
});

const sendIcon = (_req: Request, res: Response) => {
  res.type("image/png").send(iconPng());
};
app.get("/icon-192.png", sendIcon);
app.get("/icon-512.png", sendIcon);

// Stateless MCP: a new server + transport per request, no session to retain.
app.post("/mcp", async (req: Request, res: Response) => {
  const server = buildServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => {
    void transport.close();
    void server.close();
  });
  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
});

// In stateless mode there's no server-initiated stream or session to GET/DELETE.
const methodNotAllowed = (_req: Request, res: Response) => {
  res.status(405).json({
    jsonrpc: "2.0",
    error: { code: -32000, message: "Method not allowed (stateless server)." },
    id: null,
  });
};
app.get("/mcp", methodNotAllowed);
app.delete("/mcp", methodNotAllowed);

const port = Number(process.env.ORACLE_MCP_PORT ?? 4281);
const host = process.env.ORACLE_MCP_HOST ?? "127.0.0.1";
app.listen(port, host, () => {
  console.log(`oracle-mcp listening on http://${host}:${port}/mcp`);
  // Watch the native backend over WS and fan session activity out to subscribers
  // (the Telegram bridge). Owns the single long-lived client socket.
  startActivityListener();
  // Telegram bridge (juancode-c6y): if TELEGRAM_BOT_TOKEN is set, long-poll Telegram
  // and route messages through the same Oracle backend as the browser chat.
  startTelegramBridge();
});
