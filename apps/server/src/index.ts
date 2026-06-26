import { createServer } from "node:http";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync, type Dirent } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import express from "express";
import { authEnabled, authMiddleware } from "./auth.ts";
import { DEFAULT_CWD, PORT } from "./config.ts";
import { getBeads } from "./beads.ts";
import { commentDb, reviewDb, sessionDb } from "./db.ts";
import type { SearchHit } from "./db.ts";
import { editors } from "./editor.ts";
import { terminals } from "./terminal.ts";
import { createPr, getOpenPrs } from "./gh.ts";
import { commitAll, getDiff, getGitState, listWorktrees, pushCurrent, removeWorktree } from "./git.ts";
import { generateCommitMessage } from "./commit.ts";
import { runReview } from "./review.ts";
import type { CommentSide, DiffComment } from "./protocol.ts";
import { PROVIDERS } from "./providers.ts";
import { registry } from "./registry.ts";
import { getAllStatus } from "./status.ts";
import { healthMonitor } from "./healthMonitor.ts";
import { setupWebSocket } from "./ws.ts";

sessionDb.markOrphansExited();
// Begin the periodic health-check sweep (dead/stale session detection).
healthMonitor.start();

const app = express();
app.use(express.json());

// Opt-in token auth (gated on JUANCODE_TOKEN). No-op when the env var is unset,
// so localhost `pnpm dev` is unchanged. When set, every request below — API and
// the static SPA — requires the token via Bearer header, ?token=, or cookie.
app.use(authMiddleware());

app.get("/api/health", (_req, res) => res.json({ ok: true }));

app.get("/api/providers", (_req, res) => {
  res.json(Object.values(PROVIDERS).map(({ id, label }) => ({ id, label })));
});

/**
 * Per-provider auth + MCP status, so users can confirm (e.g.) pencil and their
 * claude.ai connectors / codex config.toml servers are live before starting a
 * session. Shells out to the genuine CLIs (`claude mcp list`, `codex mcp list`)
 * with the user's real env untouched — same fidelity as everything else here.
 */
app.get("/api/status", async (_req, res) => {
  try {
    res.json(await getAllStatus());
  } catch (err) {
    res.status(500).json({ error: err instanceof Error ? err.message : String(err) });
  }
});

app.get("/api/sessions", (_req, res) => {
  res.json(sessionDb.list());
});

/**
 * Full-text search over session titles + scrollback (SQLite FTS5). Returns up to
 * 50 matching sessions, each with a highlighted snippet of the match. A blank or
 * single-character query returns an empty list rather than flooding results.
 */
app.get("/api/search", (req, res) => {
  const q = (typeof req.query.q === "string" ? req.query.q : "").trim();
  if (q.length < 2) return res.json([] satisfies SearchHit[]);
  try {
    res.json(sessionDb.search(q, 50));
  } catch (err) {
    res.status(400).json({ error: errMsg(err) });
  }
});

app.get("/api/sessions/:id", (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  res.json(meta);
});

/**
 * Permanently delete a session: kill its live pty (if any), drop it from sqlite,
 * and remove its auto-created git worktree (if it owned one). Worktree removal is
 * best-effort — a failure is logged but doesn't fail the delete.
 */
app.delete("/api/sessions/:id", async (req, res) => {
  const meta = sessionDb.get(req.params.id);
  const live = registry.get(req.params.id);
  if (live) live.kill();
  const deleted = sessionDb.delete(req.params.id);
  if (!deleted) return res.status(404).json({ error: "not found" });
  if (meta?.worktreePath) {
    try {
      await removeWorktree(meta.worktreePath);
    } catch (err) {
      console.error(`Failed to remove worktree ${meta.worktreePath}: ${errMsg(err)}`);
    }
  }
  res.status(204).end();
});

const errMsg = (err: unknown): string => (err instanceof Error ? err.message : String(err));

/**
 * Resolve which worktree a diff/git-action targets. Defaults to the session's
 * own cwd; an optional requested path selects a different worktree of the same
 * repo, validated against the repo's worktree list so a client can't operate on
 * an arbitrary directory. Throws `Not a worktree of this repo` on a bad path.
 */
async function resolveTargetCwd(baseCwd: string, requested: unknown): Promise<string> {
  const req = typeof requested === "string" ? requested : "";
  if (req && resolve(req) !== resolve(baseCwd)) {
    const match = (await listWorktrees(baseCwd)).find((w) => resolve(w.path) === resolve(req));
    if (!match) throw new Error("Not a worktree of this repo");
    return match.path;
  }
  return baseCwd;
}

/**
 * Git diff of the session's working dir vs HEAD (incl. staged + untracked).
 * An optional `?cwd=` selects a different worktree of the same repo (used by the
 * worktree picker).
 */
app.get("/api/sessions/:id/diff", async (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  try {
    res.json(await getDiff(await resolveTargetCwd(meta.cwd, req.query.cwd)));
  } catch (err) {
    res.status(500).json({ error: errMsg(err) });
  }
});

/** Working-tree git state (branch, ahead/behind, dirty) for the commit/push/PR CTAs. */
app.get("/api/sessions/:id/git", async (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  try {
    res.json(await getGitState(await resolveTargetCwd(meta.cwd, req.query.cwd)));
  } catch (err) {
    res.status(400).json({ error: errMsg(err) });
  }
});

/** Draft a commit message for the current diff via the genuine `claude` CLI. */
app.post("/api/sessions/:id/commit-message", async (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  try {
    const cwd = await resolveTargetCwd(meta.cwd, req.body?.cwd);
    const diff = await getDiff(cwd);
    res.json({ message: await generateCommitMessage(cwd, diff.files) });
  } catch (err) {
    res.status(500).json({ error: errMsg(err) });
  }
});

/** Stage everything and commit it with the supplied message. */
app.post("/api/sessions/:id/commit", async (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  const message = typeof req.body?.message === "string" ? req.body.message.trim() : "";
  if (!message) return res.status(400).json({ error: "message required" });
  try {
    const cwd = await resolveTargetCwd(meta.cwd, req.body?.cwd);
    res.json(await commitAll(cwd, message));
  } catch (err) {
    res.status(500).json({ error: errMsg(err) });
  }
});

/** Push the current branch (sets the upstream to origin on first push). */
app.post("/api/sessions/:id/push", async (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  try {
    res.json(await pushCurrent(await resolveTargetCwd(meta.cwd, req.body?.cwd)));
  } catch (err) {
    res.status(500).json({ error: errMsg(err) });
  }
});

/** Open a pull request for the current branch (pushes it first, then `gh pr create`). */
app.post("/api/sessions/:id/pr", async (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  const title = typeof req.body?.title === "string" ? req.body.title.trim() : "";
  if (!title) return res.status(400).json({ error: "title required" });
  const body = typeof req.body?.body === "string" ? req.body.body : "";
  const draft = Boolean(req.body?.draft);
  try {
    const cwd = await resolveTargetCwd(meta.cwd, req.body?.cwd);
    await pushCurrent(cwd); // ensure the branch is on the remote before opening the PR
    res.json(await createPr(cwd, { title, body, draft }));
  } catch (err) {
    res.status(500).json({ error: errMsg(err) });
  }
});

/** Linked git worktrees of the session's repo (for the diff worktree picker). */
app.get("/api/sessions/:id/worktrees", async (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  try {
    res.json(await listWorktrees(meta.cwd));
  } catch (err) {
    res.status(500).json({ error: err instanceof Error ? err.message : String(err) });
  }
});

/** Raw text content of a file in the session's working dir (for the md preview). */
app.get("/api/sessions/:id/file", (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  const rel = typeof req.query.path === "string" ? req.query.path : "";
  if (!rel) return res.status(400).json({ error: "path required" });
  // Guard against path traversal: the resolved path must stay under the cwd.
  const full = resolve(meta.cwd, rel);
  const within = relative(meta.cwd, full);
  if (within.startsWith("..") || resolve(within) === within) {
    return res.status(400).json({ error: "path escapes working dir" });
  }
  try {
    res.json({ path: rel, content: readFileSync(full, "utf8") });
  } catch (err) {
    res.status(404).json({ error: err instanceof Error ? err.message : String(err) });
  }
});

/** Open pull requests for a work folder (via the user's real `gh` CLI). */
app.get("/api/prs", async (req, res) => {
  const cwd = typeof req.query.cwd === "string" ? req.query.cwd : "";
  if (!cwd) return res.status(400).json({ error: "cwd required" });
  try {
    res.json(await getOpenPrs(cwd));
  } catch (err) {
    res.status(500).json({ error: err instanceof Error ? err.message : String(err) });
  }
});

/** Beads (bd) issues for the session's working folder. */
app.get("/api/sessions/:id/beads", async (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  try {
    res.json(await getBeads(meta.cwd));
  } catch (err) {
    res.status(500).json({ error: err instanceof Error ? err.message : String(err) });
  }
});

/** Cached 'Review with Claude' findings for a session, or null if none yet. */
app.get("/api/sessions/:id/review", (req, res) => {
  if (!sessionDb.get(req.params.id)) return res.status(404).json({ error: "not found" });
  res.json(reviewDb.get(req.params.id));
});

/**
 * Run a fresh 'Review with Claude' pass over the session's working-tree diff,
 * cache it, and return the findings. Feeds the user's own inline comments to
 * the model as steering context. Runs the genuine `claude` CLI with the real
 * env — same fidelity as a session pty.
 */
app.post("/api/sessions/:id/review", async (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  try {
    const diff = await getDiff(meta.cwd);
    const result = await runReview(meta.cwd, diff.files, commentDb.list(req.params.id), Date.now());
    reviewDb.save(req.params.id, result);
    res.json(result);
  } catch (err) {
    res.status(500).json({ error: err instanceof Error ? err.message : String(err) });
  }
});

/** Inline review comments for a session's diff. */
app.get("/api/sessions/:id/comments", (req, res) => {
  if (!sessionDb.get(req.params.id)) return res.status(404).json({ error: "not found" });
  res.json(commentDb.list(req.params.id));
});

app.post("/api/sessions/:id/comments", (req, res) => {
  if (!sessionDb.get(req.params.id)) return res.status(404).json({ error: "not found" });
  const { file, side, line, endLine, body } = req.body ?? {};
  // endLine is optional and defaults to a single-line comment.
  const end = endLine === undefined ? line : endLine;
  if (
    typeof file !== "string" ||
    (side !== "old" && side !== "new") ||
    !Number.isInteger(line) ||
    !Number.isInteger(end) ||
    typeof body !== "string" ||
    !body.trim()
  ) {
    return res.status(400).json({ error: "file, side ('old'|'new'), integer line, and body required" });
  }
  const comment: DiffComment = {
    id: randomUUID(),
    sessionId: req.params.id,
    file,
    side: side as CommentSide,
    line: Math.min(line, end),
    endLine: Math.max(line, end),
    body: body.trim(),
    createdAt: Date.now(),
  };
  commentDb.add(comment);
  res.status(201).json(comment);
});

/** Drop every comment for a session — called once a batched review is sent. */
app.delete("/api/sessions/:id/comments", (req, res) => {
  if (!sessionDb.get(req.params.id)) return res.status(404).json({ error: "not found" });
  commentDb.clear(req.params.id);
  res.status(204).end();
});

app.delete("/api/sessions/:id/comments/:commentId", (req, res) => {
  const removed = commentDb.remove(req.params.id, req.params.commentId);
  if (!removed) return res.status(404).json({ error: "not found" });
  res.status(204).end();
});

/** Where dropped files land. The CLI runs on this same machine, so a temp-dir
 *  path is directly readable by `claude`/`codex` once typed into the prompt. */
const UPLOAD_DIR = join(tmpdir(), "juancode-uploads");

/** Strip a client-supplied filename down to a safe, space-free basename. */
function safeUploadName(raw: string): string {
  const base = raw.split(/[\\/]/).pop() ?? "";
  const cleaned = base.replace(/[^A-Za-z0-9._-]/g, "_").replace(/^\.+/, "");
  return cleaned.slice(-128) || "file";
}

/**
 * Accept a dragged file's raw bytes and persist them to the upload dir, then
 * return the absolute path. Browsers don't expose a dragged file's real local
 * path, so the web client uploads the bytes here and feeds the saved path to
 * the CLI prompt. `express.raw` handles any content type for this route only;
 * the global json parser leaves non-json bodies untouched.
 */
app.post("/api/uploads", express.raw({ type: () => true, limit: "100mb" }), (req, res) => {
  const body = req.body as Buffer;
  if (!Buffer.isBuffer(body) || body.length === 0) {
    return res.status(400).json({ error: "empty upload" });
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

/** Directories we never descend into when searching — noisy and rarely a cwd. */
const SEARCH_SKIP = new Set(["node_modules", "dist", "build", "coverage", "vendor", "target"]);

/**
 * Bounded, depth-limited recursive search for directories whose name matches
 * `query` under `root`. Skips hidden + heavy dirs and caps results so a search
 * near the home directory can't wander the whole disk.
 */
function searchDirs(root: string, query: string, limit = 200, maxDepth = 6): DirEntry[] {
  const q = query.toLowerCase();
  const results: DirEntry[] = [];
  const stack: Array<{ dir: string; depth: number }> = [{ dir: root, depth: 0 }];
  while (stack.length > 0 && results.length < limit) {
    const { dir, depth } = stack.pop()!;
    let entries: Dirent[];
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue; // unreadable dir — skip
    }
    for (const e of entries) {
      if (!e.isDirectory() || e.name.startsWith(".") || SEARCH_SKIP.has(e.name)) continue;
      const full = join(dir, e.name);
      if (e.name.toLowerCase().includes(q)) {
        // Show the path relative to the search root so matches are locatable.
        results.push({ name: relative(root, full), path: full });
      }
      if (depth < maxDepth) stack.push({ dir: full, depth: depth + 1 });
    }
  }
  return results.sort((a, b) => a.name.localeCompare(b.name));
}

interface DirEntry {
  name: string;
  path: string;
}

/** Lightweight directory browser so the UI can pick a working directory. */
app.get("/api/dirs", (req, res) => {
  const path = resolve(typeof req.query.path === "string" && req.query.path ? req.query.path : DEFAULT_CWD);
  const query = typeof req.query.q === "string" ? req.query.q.trim() : "";
  try {
    const parent = dirname(path);
    const base = { path, parent: parent === path ? null : parent };
    if (query) {
      res.json({ ...base, entries: searchDirs(path, query), search: true });
      return;
    }
    const entries = readdirSync(path, { withFileTypes: true })
      .filter((e) => e.isDirectory() && !e.name.startsWith("."))
      .map((e) => ({ name: e.name, path: join(path, e.name) }))
      .sort((a, b) => a.name.localeCompare(b.name));
    res.json({ ...base, entries, search: false });
  } catch (err) {
    res.status(400).json({ error: err instanceof Error ? err.message : String(err) });
  }
});

// Serve the built web app in production (apps/web/dist), if present.
const here = dirname(fileURLToPath(import.meta.url));
const webDist = resolve(here, "../../web/dist");
if (existsSync(webDist)) {
  app.use(express.static(webDist));
  app.get(/.*/, (_req, res) => res.sendFile(join(webDist, "index.html")));
}

const server = createServer(app);
setupWebSocket(server);

server.listen(PORT, () => {
  console.log(`juancode server listening on http://localhost:${PORT}`);
  for (const p of Object.values(PROVIDERS)) {
    console.log(`  ${p.label}: ${p.command}`);
  }
  if (!existsSync(webDist)) {
    console.log("  (web not built — run the Vite dev server with `pnpm dev:web`)");
  }
  console.log(
    authEnabled()
      ? "  auth: ENABLED (JUANCODE_TOKEN set) — token required on HTTP + WS"
      : "  auth: disabled (set JUANCODE_TOKEN to require a token for remote access)",
  );
});

let shuttingDown = false;
function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log("\nShutting down, killing live sessions…");
  registry.killAll();
  editors.killAll();
  terminals.killAll();
  server.close(() => process.exit(0));
  // Force-destroy lingering connections (open WebSockets) so the listener
  // releases port 4280 immediately — otherwise tsx's restart races us and the
  // new process hits EADDRINUSE.
  server.closeAllConnections();
  setTimeout(() => process.exit(0), 500).unref();
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
