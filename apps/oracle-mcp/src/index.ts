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

import express, { type Request, type Response } from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import {
  appendAsk,
  appendDispatch,
  createIssue,
  listIssues,
  listSessions,
  oracleChat,
  resetChat,
} from "./oracle.ts";
import { consoleHtml } from "./ui.ts";

type ToolResult = {
  content: { type: "text"; text: string }[];
  isError?: boolean;
};

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

  return server;
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

app.post("/api/chat", async (req: Request, res: Response) => {
  try {
    const text = (req.body ?? {}).text;
    if (typeof text !== "string" || !text.trim()) {
      res.status(400).send("text is required");
      return;
    }
    res.json(await oracleChat(text));
  } catch (e) {
    sendErr(res, e);
  }
});

app.post("/api/chat/reset", async (_req: Request, res: Response) => {
  try {
    await resetChat();
    res.json({ ok: true });
  } catch (e) {
    sendErr(res, e);
  }
});

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
});
