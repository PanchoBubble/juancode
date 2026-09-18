import { mkdtempSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, describe, expect, it } from "vitest";

import {
  conformancePort,
  DEFAULT_PORT,
  findCrashReport,
  FIXTURES,
  freePort,
  isolatedParentEnv,
  startCore,
  type CoreUnderTest,
} from "./core.ts";

describe("conformancePort", () => {
  it("defaults when the variable is unset or empty", () => {
    expect(conformancePort(undefined)).toBe(DEFAULT_PORT);
    expect(conformancePort("")).toBe(DEFAULT_PORT);
    expect(conformancePort("  ")).toBe(DEFAULT_PORT);
  });

  it("keeps a port a caller named", () => {
    expect(conformancePort("4300")).toBe(4300);
  });

  it("reads 0 as a request for an ephemeral port rather than as a default", () => {
    expect(conformancePort("0")).toBe(0);
  });

  it("refuses something that is not a port instead of silently defaulting", () => {
    expect(() => conformancePort("nope")).toThrow(/not a port/);
    expect(() => conformancePort("70000")).toThrow(/not a port/);
    expect(() => conformancePort("-1")).toThrow(/not a port/);
    expect(() => conformancePort("4300.5")).toThrow(/not a port/);
  });
});

describe("freePort", () => {
  it("returns a port that is actually free to bind", async () => {
    const port = await freePort();
    expect(port).toBeGreaterThan(1024);
    expect(port).not.toBe(4280);
    expect(port).not.toBe(4281);
    // The point of the allocation is that the caller can now bind it; if the
    // probe socket had been left open this would fail with EADDRINUSE.
    await new Promise<void>((resolve, reject) => {
      const srv = createServer();
      srv.on("error", reject);
      srv.listen({ host: "127.0.0.1", port }, () => srv.close(() => resolve()));
    });
  });

  it("does not hand out a port something is already listening on", async () => {
    const taken = await freePort();
    const holder = createServer();
    await new Promise<void>((resolve, reject) => {
      holder.on("error", reject);
      holder.listen({ host: "127.0.0.1", port: taken }, () => resolve());
    });
    try {
      for (let i = 0; i < 5; i++) expect(await freePort()).not.toBe(taken);
    } finally {
      await new Promise<void>((resolve) => holder.close(() => resolve()));
    }
  });
});

describe("isolatedParentEnv", () => {
  it("strips every core knob the parent shell happens to carry", () => {
    const env = isolatedParentEnv({
      PATH: "/usr/bin",
      HOME: "/Users/someone",
      // The one that ends a core mid-run: the daemon reads it, arms its lifetime
      // watchdog against that pid, and shuts itself down a grace period after that
      // process goes. It is in the environment of every agent session a
      // launcher-owned daemon spawned, so a suite run inside one inherits it.
      JUANCODE_OWNER_PID: "4242",
      JUANCODE_OWNER_GRACE_SECONDS: "5",
      JUANCODE_OPENCODE_DB: "/Users/someone/real.db",
      JUANCODE_REAP_SWEEP_MS: "50",
      JUANCODED_DATA_DIR: "/Users/someone/.juancode/rust-core",
      JUANCODED_SOCKET: "/Users/someone/.juancode/juancoded.sock",
    });
    expect(env).toEqual({ PATH: "/usr/bin", HOME: "/Users/someone" });
  });

  it("keeps the passthrough knob, which changes how loud a core is and nothing else", () => {
    const env = isolatedParentEnv({ JUANCODED_LOG: "debug", JUANCODE_OWNER_PID: "1" });
    expect(env).toEqual({ JUANCODED_LOG: "debug" });
  });

  it("drops the suite's own variables too, since no core reads them", () => {
    const env = isolatedParentEnv({ JUANCODE_CONFORMANCE_PORT: "0", LANG: "en_GB.UTF-8" });
    expect(env).toEqual({ LANG: "en_GB.UTF-8" });
  });
});

describe("findCrashReport", () => {
  // A directory per case, because these are asserted on mtime and a file another
  // case wrote with a stamp in its own future would be the newest one here.
  const dirs: string[] = [];
  const freshDir = () => {
    const dir = mkdtempSync(join(tmpdir(), "juancode-crash-reports-"));
    dirs.push(dir);
    return dir;
  };
  afterAll(() => dirs.forEach((d) => rmSync(d, { recursive: true, force: true })));

  const write = (dir: string, name: string, body: string, mtimeMs: number) => {
    const path = join(dir, name);
    writeFileSync(path, body);
    utimesSync(path, mtimeMs / 1000, mtimeMs / 1000);
    return path;
  };

  it("returns nothing when the directory does not exist", () => {
    expect(findCrashReport("juancoded", 0, join(freshDir(), "definitely-not-here"))).toBeNull();
  });

  it("ignores a report written before this core booted", () => {
    const dir = freshDir();
    const booted = Date.now();
    write(dir, "juancoded-2026-09-04-120000.ips", "an older run's crash", booted - 60_000);
    expect(findCrashReport("juancoded", booted, dir)).toBeNull();
  });

  it("ignores another process's crash, however recent", () => {
    const dir = freshDir();
    const booted = Date.now();
    write(dir, "Slack Helper-2026-09-18-120000.ips", "not ours", booted + 1000);
    expect(findCrashReport("juancoded", booted, dir)).toBeNull();
  });

  it("returns the newest report for this core, with its path", () => {
    const dir = freshDir();
    const booted = Date.now();
    write(dir, "juancoded-2026-09-18-120000.ips", "the older one", booted + 1000);
    const newest = write(dir, "juancoded-2026-09-18-120500.ips", "EXC_BAD_ACCESS", booted + 5000);
    const found = findCrashReport("juancoded", booted, dir);
    expect(found).toContain("EXC_BAD_ACCESS");
    expect(found).toContain(newest);
    expect(found).not.toContain("the older one");
  });

  it("truncates a report rather than carrying every thread's stack", () => {
    const dir = freshDir();
    const booted = Date.now();
    write(dir, "juancoded-2026-09-18-130000.ips", "x".repeat(20_000), booted + 1000);
    const found = findCrashReport("juancoded", booted, dir) ?? "";
    expect(found).toContain("(truncated)");
    expect(found.length).toBeLessThan(8_000);
  });
});

describe("the environment a booted core actually gets", () => {
  // The end-to-end half of `isolatedParentEnv`: a real child process, started the
  // way the suite starts a core, reporting the knobs it was handed.
  //
  // This is the hazard juancode-jyl9 is about. An agent session spawned by a
  // launcher-owned daemon inherits JUANCODE_OWNER_PID, so a conformance run inside
  // one used to boot a core that read the developer's launcher as its owner — and a
  // core with an owner ends ITSELF once that owner is gone, mid-run, through the
  // orderly shutdown path: no panic, no crash, just a daemon that stops answering.
  it("carries no ownership claim, however the parent shell was launched", async () => {
    const leaked = { pid: process.env.JUANCODE_OWNER_PID, db: process.env.JUANCODE_OPENCODE_DB };
    process.env.JUANCODE_OWNER_PID = String(process.pid);
    process.env.JUANCODE_OPENCODE_DB = "/Users/someone/real-opencode.db";
    let core: CoreUnderTest | undefined;
    try {
      core = await startCore({ core: "rust", exe: join(FIXTURES, "fake-core.mjs"), port: 0 });
      const printed = core.log();
      expect(printed).toContain("fake-core: core env ");
      expect(printed).not.toContain("JUANCODE_OWNER_PID");
      expect(printed).not.toContain("JUANCODE_OPENCODE_DB");
      // And the isolation the boot does set is still there, so this is a filter and
      // not an empty environment.
      expect(printed).toContain("JUANCODED_DATA_DIR");
    } finally {
      await core?.stop();
      if (leaked.pid === undefined) delete process.env.JUANCODE_OWNER_PID;
      else process.env.JUANCODE_OWNER_PID = leaked.pid;
      if (leaked.db === undefined) delete process.env.JUANCODE_OPENCODE_DB;
      else process.env.JUANCODE_OPENCODE_DB = leaked.db;
    }
  });
});
