#!/usr/bin/env node
// A stand-in core for testing the HARNESS, not a core.
//
// It answers the health probe and nothing else. It exists so `death.test.ts` can
// SIGKILL a real process mid-run and watch what the report says, without a
// twenty-minute cargo build and without a core that anything else depends on.
//
// It prints on both streams at boot, deliberately: the thing under test is
// whether the harness still has that output in hand after the process is gone.
//
// It also prints the core knobs it was handed, because "which JUANCODE_* variables
// reach a booted core" is itself a thing the harness has to be able to assert: a
// leaked JUANCODE_OWNER_PID arms the real daemon's lifetime watchdog and makes it
// end itself mid-run.

import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { setInterval, setTimeout } from "node:timers";

const port = Number(process.env.JUANCODE_PORT ?? process.env.JUANCODED_PORT ?? 0);

const knobs = Object.keys(process.env)
  .filter((k) => /^JUANCODED?_/.test(k))
  .sort();

console.log("fake-core: booting");
console.log(`fake-core: core env ${knobs.join(",") || "(none)"}`);
console.error("fake-core: this line is on stderr");

// Stand in for the core that lost the race for its own port: something else ends up
// serving it, and the process the harness spawned is already gone by the time the
// health probe answers. Faithful to the real shape — a core that cannot bind exits at
// once while the winner keeps answering — and reproducible, which a real bind race is
// not. The squatter ends itself after a bounded time, so a failed assertion cannot
// leave one behind.
if (process.env.FAKE_CORE_HANDOFF === "1") {
  const squatter = spawn(process.execPath, [process.argv[1]], {
    env: { ...process.env, FAKE_CORE_HANDOFF: "0", FAKE_CORE_SELF_DESTRUCT_MS: "30000" },
    stdio: "ignore",
    detached: true,
  });
  squatter.unref();
  console.log(`fake-core: handed the port to pid ${squatter.pid} and is exiting`);
  // Not `process.exit` here: the squatter has to be answering before this process's
  // exit matters, or the harness sees an ordinary boot failure instead of a port
  // served by somebody it never spawned.
  setTimeout(() => process.exit(0), 700);
} else {
  const server = createServer((req, res) => {
    if (req.url === "/api/health" || req.url === "/health") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end('{"ok":true}');
      return;
    }
    res.writeHead(404);
    res.end();
  });

  server.listen(port, "127.0.0.1", () => {
    console.log(`fake-core: listening on ${port}`);
  });

  // Stop serving without dying. The other half of what a harness has to be able to
  // tell apart: a core that ENDED and a core that is still in the process table and
  // no longer listening produce the same ECONNREFUSED for every scenario after them,
  // the same empty log, and completely different bugs. The timer is what keeps the
  // process alive once the listener is gone, since node exits when nothing is left.
  process.on("SIGUSR1", () => {
    console.log("fake-core: closing the listener and staying alive");
    server.close();
    setInterval(() => {}, 1000);
  });

  // The backstop for the handed-off squatter above: nothing else will reap it.
  const selfDestructMs = Number(process.env.FAKE_CORE_SELF_DESTRUCT_MS ?? 0);
  if (selfDestructMs > 0) setTimeout(() => process.exit(0), selfDestructMs);
}
