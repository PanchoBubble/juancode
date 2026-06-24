import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  commitAll,
  createWorktree,
  getDiff,
  getGitState,
  listWorktrees,
  pushCurrent,
  removeWorktree,
} from "./git.ts";

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

describe("getGitState", () => {
  it("returns git:false for a non-git directory", async () => {
    const plain = mkdtempSync(join(tmpdir(), "juancode-plain-"));
    try {
      expect((await getGitState(plain)).git).toBe(false);
    } finally {
      rmSync(plain, { recursive: true, force: true });
    }
  });

  it("reports a dirty tree with no remote", async () => {
    writeFileSync(join(dir, "a.txt"), "x\n");
    const s = await getGitState(dir);
    expect(s.git).toBe(true);
    expect(s.dirty).toBe(true);
    expect(s.remote).toBe(false);
    expect(s.upstream).toBeNull();
  });

  it("becomes clean and counts a local commit as ahead with no upstream", async () => {
    writeFileSync(join(dir, "a.txt"), "x\n");
    git("add", "-A");
    git("commit", "-qm", "init");
    const s = await getGitState(dir);
    expect(s.dirty).toBe(false);
    expect(s.ahead).toBe(1);
  });
});

describe("commitAll", () => {
  it("stages everything and commits, leaving a clean tree", async () => {
    writeFileSync(join(dir, "a.txt"), "one\n");
    writeFileSync(join(dir, "b.txt"), "two\n");
    const r = await commitAll(dir, "feat: add a and b");
    expect(r.subject).toBe("feat: add a and b");
    expect(r.sha).toMatch(/^[0-9a-f]{7,}$/);
    expect((await getGitState(dir)).dirty).toBe(false);
  });

  it("rejects when there is nothing to commit", async () => {
    writeFileSync(join(dir, "a.txt"), "one\n");
    await commitAll(dir, "init");
    await expect(commitAll(dir, "again")).rejects.toThrow(/nothing to commit/i);
  });
});

describe("createWorktree / removeWorktree", () => {
  it("creates a worktree on a new juancode/ branch and removes it", async () => {
    writeFileSync(join(dir, "a.txt"), "x\n");
    await commitAll(dir, "init");

    const wt = await createWorktree(dir, "abc123de");
    try {
      expect(wt.branch).toBe("juancode/abc123de");
      expect(existsSync(wt.path)).toBe(true);
      // It's a real linked worktree of the same repo, on its own branch.
      const trees = await listWorktrees(dir);
      const found = trees.find((t) => resolve(t.path) === resolve(wt.path));
      expect(found?.branch).toBe("juancode/abc123de");
      expect(found?.main).toBe(false);

      await removeWorktree(wt.path);
      expect(existsSync(wt.path)).toBe(false);
      const after = await listWorktrees(dir);
      expect(after.some((t) => resolve(t.path) === resolve(wt.path))).toBe(false);
    } finally {
      // The sibling <repo>-worktrees parent dir lives outside `dir`'s cleanup.
      rmSync(dirname(wt.path), { recursive: true, force: true });
    }
  });

  it("force-removes a worktree with uncommitted changes", async () => {
    writeFileSync(join(dir, "a.txt"), "x\n");
    await commitAll(dir, "init");
    const wt = await createWorktree(dir, "dirtywt");
    try {
      writeFileSync(join(wt.path, "scratch.txt"), "uncommitted\n");
      await removeWorktree(wt.path);
      expect(existsSync(wt.path)).toBe(false);
    } finally {
      rmSync(dirname(wt.path), { recursive: true, force: true });
    }
  });

  it("rejects isolating a non-git directory", async () => {
    const plain = mkdtempSync(join(tmpdir(), "juancode-plain-"));
    try {
      await expect(createWorktree(plain, "x")).rejects.toThrow(/not a git repository/i);
    } finally {
      rmSync(plain, { recursive: true, force: true });
    }
  });
});

describe("pushCurrent", () => {
  it("pushes to a bare remote, setting the upstream on first push", async () => {
    const remote = mkdtempSync(join(tmpdir(), "juancode-remote-"));
    try {
      execFileSync("git", ["init", "-q", "--bare", remote]);
      git("remote", "add", "origin", remote);
      writeFileSync(join(dir, "a.txt"), "one\n");
      await commitAll(dir, "init");
      expect((await getGitState(dir)).upstream).toBeNull();

      const r = await pushCurrent(dir);
      expect(r.branch).toBeTruthy();

      const after = await getGitState(dir);
      expect(after.upstream).toContain("origin/");
      expect(after.ahead).toBe(0);
    } finally {
      rmSync(remote, { recursive: true, force: true });
    }
  });
});
