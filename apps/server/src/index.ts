import { createServer } from "node:http";
import { existsSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
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

/** Lightweight directory browser so the UI can pick a working directory. */
app.get("/api/dirs", (req, res) => {
  const path = resolve(typeof req.query.path === "string" && req.query.path ? req.query.path : DEFAULT_CWD);
  try {
    const entries = readdirSync(path, { withFileTypes: true })
      .filter((e) => e.isDirectory() && !e.name.startsWith("."))
      .map((e) => ({ name: e.name, path: join(path, e.name) }))
      .sort((a, b) => a.name.localeCompare(b.name));
    const parent = dirname(path);
    res.json({ path, parent: parent === path ? null : parent, entries });
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
