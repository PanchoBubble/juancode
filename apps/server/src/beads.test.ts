import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { getBeads } from "./beads.ts";

/** Is the `bd` CLI available on PATH? Tracker-backed assertions need it. */
function hasBd(): boolean {
  try {
    execFileSync("bd", ["version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

const bd = hasBd();

describe("getBeads", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "juancode-bd-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("returns available:false for a folder with no tracker", async () => {
    const r = await getBeads(dir);
    expect(r.available).toBe(false);
    expect(r.issues).toEqual([]);
    expect(r.error).toBeTruthy();
  });

  it.runIf(bd)("lists issues from a real tracker, mapped to camelCase", async () => {
    execFileSync("bd", ["init"], { cwd: dir, stdio: "ignore" });
    execFileSync("bd", ["create", "First task", "-t", "task", "-p", "1"], { cwd: dir, stdio: "ignore" });

    const r = await getBeads(dir);
    expect(r.available).toBe(true);
    expect(r.issues.length).toBe(1);
    const issue = r.issues[0]!;
    expect(issue.title).toBe("First task");
    expect(issue.priority).toBe(1);
    expect(issue.issueType).toBe("task");
    expect(typeof issue.ready).toBe("boolean");
    expect(typeof issue.blocked).toBe("boolean");
  });
});
