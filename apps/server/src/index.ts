import { createServer } from "node:http";
import { existsSync, readdirSync, type Dirent } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import express from "express";
import { DEFAULT_CWD, PORT } from "./config.ts";
import { getBeads } from "./beads.ts";
import { commentDb, sessionDb } from "./db.ts";
import { getDiff } from "./git.ts";
import type { CommentSide, DiffComment } from "./protocol.ts";
import { PROVIDERS } from "./providers.ts";
import { registry } from "./registry.ts";
import { getAllStatus } from "./status.ts";
import { setupWebSocket } from "./ws.ts";

sessionDb.markOrphansExited();

const app = express();
app.use(express.json());

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

app.get("/api/sessions/:id", (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  res.json(meta);
});

/** Git diff of the session's working dir vs HEAD (incl. staged + untracked). */
app.get("/api/sessions/:id/diff", async (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  try {
    res.json(await getDiff(meta.cwd));
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

/** Inline review comments for a session's diff. */
app.get("/api/sessions/:id/comments", (req, res) => {
  if (!sessionDb.get(req.params.id)) return res.status(404).json({ error: "not found" });
  res.json(commentDb.list(req.params.id));
});

app.post("/api/sessions/:id/comments", (req, res) => {
  if (!sessionDb.get(req.params.id)) return res.status(404).json({ error: "not found" });
  const { file, side, line, body } = req.body ?? {};
  if (
    typeof file !== "string" ||
    (side !== "old" && side !== "new") ||
    !Number.isInteger(line) ||
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
    line,
    body: body.trim(),
    createdAt: Date.now(),
  };
  commentDb.add(comment);
  res.status(201).json(comment);
});

app.delete("/api/sessions/:id/comments/:commentId", (req, res) => {
  const removed = commentDb.remove(req.params.id, req.params.commentId);
  if (!removed) return res.status(404).json({ error: "not found" });
  res.status(204).end();
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
});

function shutdown() {
  console.log("\nShutting down, killing live sessions…");
  registry.killAll();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
