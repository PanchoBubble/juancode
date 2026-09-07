#!/usr/bin/env node
// A stand-in core for testing the HARNESS, not a core.
//
// It answers the health probe and nothing else. It exists so `death.test.ts` can
// SIGKILL a real process mid-run and watch what the report says, without a
// twenty-minute cargo build and without a core that anything else depends on.
//
// It prints on both streams at boot, deliberately: the thing under test is
// whether the harness still has that output in hand after the process is gone.

import { createServer } from "node:http";

const port = Number(process.env.JUANCODE_PORT ?? process.env.JUANCODED_PORT ?? 0);

console.log("fake-core: booting");
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
