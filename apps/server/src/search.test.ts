import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { SessionMeta } from "./protocol.ts";
import type * as DbModule from "./db.ts";

// Point the DB at a throwaway dir BEFORE importing db.ts (it opens sqlite on import).
const tmp = mkdtempSync(join(tmpdir(), "juancode-search-"));
process.env.JUANCODE_DATA_DIR = tmp;

// Imported dynamically so the env override above lands first.
let sessionDb: typeof DbModule.sessionDb;
let toFtsMatch: typeof DbModule.toFtsMatch;

beforeAll(async () => {
  const mod = await import("./db.ts");
  sessionDb = mod.sessionDb;
  toFtsMatch = mod.toFtsMatch;
});

afterAll(() => rmSync(tmp, { recursive: true, force: true }));

const meta = (id: string, title: string): SessionMeta => ({
  id,
  provider: "claude",
  cwd: "/tmp/proj",
  title,
  status: "exited",
  exitCode: 0,
  createdAt: Date.now(),
  updatedAt: Date.now(),
  cliSessionId: null,
  skipPermissions: false,
  worktreePath: null,
});

describe("toFtsMatch", () => {
  it("turns words into ANDed prefix phrases", () => {
    expect(toFtsMatch("foo bar")).toBe('"foo"* AND "bar"*');
  });

  it("escapes embedded quotes and ignores extra whitespace", () => {
    expect(toFtsMatch('  he said "hi"  ')).toBe('"he"* AND "said"* AND """hi"""*');
  });

  it("returns empty for blank input", () => {
    expect(toFtsMatch("   ")).toBe("");
  });
});

describe("sessionDb.search", () => {
  it("finds sessions by title and by scrollback, with a highlighted snippet", () => {
    sessionDb.insert(meta("s1", "Refactor the parser"));
    sessionDb.update(meta("s1", "Refactor the parser"), "running eslint over the codebase now");
    sessionDb.insert(meta("s2", "Unrelated work"));

    const byTitle = sessionDb.search("parser");
    expect(byTitle.map((h) => h.id)).toContain("s1");

    const byScrollback = sessionDb.search("eslint");
    expect(byScrollback.map((h) => h.id)).toEqual(["s1"]);
    expect(byScrollback[0]?.snippet).toContain("[eslint]");
  });

  it("returns [] for short/blank queries and survives stray operators", () => {
    expect(sessionDb.search("")).toEqual([]);
    expect(() => sessionDb.search('"')).not.toThrow();
  });

  it("drops the FTS row when a session is deleted", () => {
    sessionDb.insert(meta("s3", "ephemeral"));
    sessionDb.update(meta("s3", "ephemeral"), "uniquetokenxyz");
    expect(sessionDb.search("uniquetokenxyz").map((h) => h.id)).toEqual(["s3"]);
    sessionDb.delete("s3");
    expect(sessionDb.search("uniquetokenxyz")).toEqual([]);
  });
});
