import { createServer } from "node:http";
import { existsSync, readdirSync, type Dirent } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import express from "express";
import { DEFAULT_CWD, PORT } from "./config.ts";
import { sessionDb } from "./db.ts";
import { PROVIDERS } from "./providers.ts";
import { registry } from "./registry.ts";
import { setupWebSocket } from "./ws.ts";

sessionDb.markOrphansExited();

const app = express();
app.use(express.json());

app.get("/api/health", (_req, res) => res.json({ ok: true }));

app.get("/api/providers", (_req, res) => {
  res.json(Object.values(PROVIDERS).map(({ id, label }) => ({ id, label })));
});

app.get("/api/sessions", (_req, res) => {
  res.json(sessionDb.list());
});

app.get("/api/sessions/:id", (req, res) => {
  const meta = sessionDb.get(req.params.id);
  if (!meta) return res.status(404).json({ error: "not found" });
  res.json(meta);
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
