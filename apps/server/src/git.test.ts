import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { getDiff } from "./git.ts";

let dir: string;

const git = (...args: string[]) => execFileSync("git", args, { cwd: dir });

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "juancode-git-"));
  git("init", "-q");
  git("config", "user.email", "test@example.com");
  git("config", "user.name", "Test");
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

describe("getDiff", () => {
  it("returns git:false for a non-git directory", async () => {
    const plain = mkdtempSync(join(tmpdir(), "juancode-plain-"));
    try {
      expect(await getDiff(plain)).toEqual({ git: false, files: [] });
    } finally {
      rmSync(plain, { recursive: true, force: true });
    }
  });

  it("reports modified, added (untracked), and deleted files vs HEAD", async () => {
    writeFileSync(join(dir, "keep.txt"), "one\ntwo\nthree\n");
    writeFileSync(join(dir, "gone.txt"), "remove me\n");
    git("add", "-A");
    git("commit", "-qm", "init");

    writeFileSync(join(dir, "keep.txt"), "one\ntwo\nthree\nfour\n"); // modified
    writeFileSync(join(dir, "new.txt"), "fresh\n"); // untracked
    rmSync(join(dir, "gone.txt")); // deleted

    const r = await getDiff(dir);
    expect(r.git).toBe(true);
    const byPath = Object.fromEntries(r.files.map((f) => [f.path, f]));

    expect(byPath["keep.txt"]?.status).toBe("modified");
    expect(byPath["keep.txt"]?.additions).toBe(1);
    expect(byPath["new.txt"]?.status).toBe("untracked");
    expect(byPath["new.txt"]?.additions).toBe(1);
    expect(byPath["gone.txt"]?.status).toBe("deleted");
    expect(byPath["gone.txt"]?.deletions).toBe(1);
  });

  it("does not misclassify a text file whose content mentions 'Binary files ' as binary", async () => {
    // Regression: binary detection must only inspect unprefixed header lines,
    // not added/removed content that happens to contain the marker string.
    writeFileSync(join(dir, "talk.txt"), 'Binary files differ\nGIT binary patch\nnormal text\n');
    const r = await getDiff(dir);
    const f = r.files.find((x) => x.path === "talk.txt");
    expect(f?.binary).toBe(false);
    expect(f?.additions).toBe(3);
    expect(f?.diff.length).toBeGreaterThan(0);
  });

  it("works in a fresh repo with no commits (empty-tree base)", async () => {
    writeFileSync(join(dir, "first.txt"), "hello\n");
    git("add", "-A"); // staged but no commit yet — HEAD does not exist

    const r = await getDiff(dir);
    expect(r.git).toBe(true);
    const f = r.files.find((x) => x.path === "first.txt");
    expect(f?.additions).toBe(1);
  });
});
