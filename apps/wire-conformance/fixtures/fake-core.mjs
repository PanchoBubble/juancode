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

import { createServer } from "node:http";

const port = Number(process.env.JUANCODE_PORT ?? process.env.JUANCODED_PORT ?? 0);

const knobs = Object.keys(process.env)
  .filter((k) => /^JUANCODED?_/.test(k))
  .sort();

console.log("fake-core: booting");
console.log(`fake-core: core env ${knobs.join(",") || "(none)"}`);
console.error("fake-core: this line is on stderr");

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
