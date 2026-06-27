import { mkdtempSync, mkdirSync, writeFileSync, rmSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { listExternalSessions, recoverCliSessionId } from "./recoverSession.ts";

const tmp = mkdtempSync(join(tmpdir(), "juancode-recover-"));
afterAll(() => rmSync(tmp, { recursive: true, force: true }));

const CWD = "/Users/someone/project";
const OTHER = "/Users/someone/other";
const T0 = Date.parse("2026-06-23T12:00:00.000Z"); // a session's createdAt

const jsonl = (records: unknown[]) => records.map((r) => JSON.stringify(r)).join("\n") + "\n";

/** Encode a cwd the way Claude names its project dirs (path separators → dashes). */
const encode = (cwd: string) => cwd.replace(/[/.]/g, "-");

/**
 * Build a Claude projects root containing one transcript per entry, each a
 * `<root>/<encoded-cwd>/<id>.jsonl` whose first record carries the cwd + start.
 */
function claudeRoot(
  name: string,
  transcripts: { id: string; cwd: string; startMs: number }[],
): string {
  const root = join(tmp, name);
  for (const t of transcripts) {
    const dir = join(root, encode(t.cwd));
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, `${t.id}.jsonl`),
      jsonl([
        { type: "mode" }, // no cwd/timestamp — must be skipped
        { type: "user", cwd: t.cwd, timestamp: new Date(t.startMs).toISOString(), message: "hi" },
      ]),
    );
  }
  return root;
}

/**
 * Build a Codex sessions root containing one `rollout-*.jsonl` per entry, each
 * with a `session_meta` header carrying the resumable id + cwd. Codex has no
 * in-record start time, so the rollout file's birthtime/mtime is the start — we
 * stamp `mtime` to a deterministic value so order is testable.
 */
function codexRoot(name: string, transcripts: { id: string; cwd: string; startMs: number }[]): string {
  const root = join(tmp, name);
  mkdirSync(root, { recursive: true });
  for (const t of transcripts) {
    const file = join(root, `rollout-${t.id}.jsonl`);
    writeFileSync(file, jsonl([{ type: "session_meta", payload: { id: t.id, cwd: t.cwd } }]));
    const when = new Date(t.startMs);
    utimesSync(file, when, when);
  }
  return root;
}

const recover = (root: string, excludeIds: string[] = [], createdAt = T0) =>
  recoverCliSessionId("claude", CWD, createdAt, new Set(excludeIds), { claudeProjects: root });

describe("recoverCliSessionId (claude)", () => {
  it("picks the transcript that began closest after the session was created", async () => {
    const root = claudeRoot("near", [
      { id: "near", cwd: CWD, startMs: T0 + 30_000 },
      { id: "later", cwd: CWD, startMs: T0 + 9 * 60_000 },
    ]);
    expect(await recover(root)).toBe("near");
  });

  it("skips ids already claimed by another session", async () => {
    const root = claudeRoot("excluded", [
      { id: "near", cwd: CWD, startMs: T0 + 30_000 },
      { id: "later", cwd: CWD, startMs: T0 + 9 * 60_000 },
    ]);
    expect(await recover(root, ["near"])).toBe("later");
  });

  it("ignores transcripts from a different working directory", async () => {
    const root = claudeRoot("other-cwd", [{ id: "elsewhere", cwd: OTHER, startMs: T0 + 30_000 }]);
    expect(await recover(root)).toBeNull();
  });

  it("rejects a match too far after creation (likely a different session)", async () => {
    const root = claudeRoot("too-late", [{ id: "stale", cwd: CWD, startMs: T0 + 20 * 60_000 }]);
    expect(await recover(root)).toBeNull();
  });

  it("rejects a transcript that began before the session was created", async () => {
    const root = claudeRoot("too-early", [{ id: "prior", cwd: CWD, startMs: T0 - 60_000 }]);
    expect(await recover(root)).toBeNull();
  });

  it("returns null when the projects root has nothing for this cwd", async () => {
    const root = claudeRoot("empty", [{ id: "x", cwd: OTHER, startMs: T0 }]);
    expect(await recover(root)).toBeNull();
  });
});

describe("listExternalSessions", () => {
  it("lists every Claude transcript for the cwd, newest first, with no time window", async () => {
    const claudeProjects = claudeRoot("ext-claude", [
      { id: "old", cwd: CWD, startMs: T0 - 60 * 60_000 }, // well before T0 — still listed
      { id: "newer", cwd: CWD, startMs: T0 + 99 * 60_000 }, // well after T0 — still listed
      { id: "elsewhere", cwd: OTHER, startMs: T0 }, // different cwd — excluded
    ]);
    const out = await listExternalSessions(CWD, { claudeProjects });
    expect(out.map((s) => s.cliSessionId)).toEqual(["newer", "old"]);
    expect(out.every((s) => s.provider === "claude")).toBe(true);
  });

  it("merges Claude and Codex candidates and sorts the combined list newest first", async () => {
    const claudeProjects = claudeRoot("ext-merge-claude", [
      { id: "c-old", cwd: CWD, startMs: T0 - 30 * 60_000 },
      { id: "c-new", cwd: CWD, startMs: T0 + 60 * 60_000 },
    ]);
    const codexSessions = codexRoot("ext-merge-codex", [
      { id: "x-mid", cwd: CWD, startMs: T0 },
      { id: "x-other", cwd: OTHER, startMs: T0 + 5 * 60_000 }, // different cwd — excluded
    ]);
    const out = await listExternalSessions(CWD, { claudeProjects, codexSessions });
    // c-new (T0+60m) > x-mid (~T0) > c-old (T0-30m); x-other excluded by cwd.
    expect(out.map((s) => `${s.provider}:${s.cliSessionId}`)).toEqual([
      "claude:c-new",
      "codex:x-mid",
      "claude:c-old",
    ]);
  });

  it("returns an empty list when neither root has anything for the cwd", async () => {
    const claudeProjects = claudeRoot("ext-none-claude", [{ id: "x", cwd: OTHER, startMs: T0 }]);
    const codexSessions = codexRoot("ext-none-codex", [{ id: "y", cwd: OTHER, startMs: T0 }]);
    expect(await listExternalSessions(CWD, { claudeProjects, codexSessions })).toEqual([]);
  });
});
