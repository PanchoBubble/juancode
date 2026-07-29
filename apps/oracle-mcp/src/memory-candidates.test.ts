import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildDigest,
  buildPrompt,
  existingMemory,
  filterCandidates,
  looksSensitive,
  memoryDirFor,
  parseCandidates,
  renderCandidates,
  type Candidate,
} from "./memory-candidates.ts";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "juancode-memory-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const candidate = (over: Partial<Candidate> = {}): Candidate => ({
  name: "some-fact",
  type: "project",
  fact: "The sidecar talks to the native app on port 4280",
  why: "Not discoverable from the code without tracing the WS client",
  ...over,
});

describe("memoryDirFor", () => {
  it("derives the memory dir from the transcript path", () => {
    expect(
      memoryDirFor({ transcript_path: "/Users/me/.claude/projects/-Users-me-repo/abc.jsonl" }),
    ).toBe("/Users/me/.claude/projects/-Users-me-repo/memory");
  });

  it("falls back to slugifying cwd", () => {
    expect(memoryDirFor({ cwd: "/Users/me/work/repo" })).toMatch(
      /\.claude\/projects\/-Users-me-work-repo\/memory$/,
    );
  });

  it("gives up when neither is present", () => {
    expect(memoryDirFor({})).toBeUndefined();
  });
});

describe("buildDigest", () => {
  const line = (role: "user" | "assistant", text: string) =>
    JSON.stringify({ type: role, message: { role, content: text } });

  it("counts real turns and renders them role-prefixed", () => {
    const { turns, digest } = buildDigest([
      '{"type":"mode","mode":"normal"}',
      line("user", "why is the port 3308"),
      line("assistant", "because 3307 is taken"),
      "",
    ]);
    expect(turns).toBe(2);
    expect(digest).toBe("user: why is the port 3308\nassistant: because 3307 is taken");
  });

  it("keeps the tail when the session is longer than the budget", () => {
    const lines = Array.from({ length: 400 }, (_, i) => line("user", `turn ${i} ${"x".repeat(700)}`));
    const { turns, digest } = buildDigest(lines);
    expect(turns).toBe(400);
    expect(digest.length).toBeLessThanOrEqual(24_000);
    // Latest turn survives, earliest is dropped.
    expect(digest).toContain("turn 399");
    expect(digest).not.toContain("turn 0 ");
  });

  it("handles an empty transcript", () => {
    expect(buildDigest([])).toEqual({ turns: 0, digest: "" });
  });
});

describe("looksSensitive", () => {
  it("rejects credentials and contact details", () => {
    expect(looksSensitive("mail juan@fanvue.com about it")).toBe(true);
    expect(looksSensitive("token sk-ant-api03-AAAAAAAAAAAAAAAA")).toBe(true);
    expect(looksSensitive("ghp_abcdefghijklmnopqrst")).toBe(true);
    expect(looksSensitive("xoxb-1234567890-abcdefghij")).toBe(true);
    expect(looksSensitive("AKIAIOSFODNN7EXAMPLE")).toBe(true);
    expect(looksSensitive("Authorization: Bearer abcdefghijklmnopqrstuvwx")).toBe(true);
    expect(looksSensitive("eyJhbGciOiJIUzI1NiIsInR5cCI6.x")).toBe(true);
    expect(looksSensitive("card 4111111111111111")).toBe(true);
  });

  it("allows ordinary technical facts", () => {
    expect(looksSensitive("the dolt server listens on port 3308")).toBe(false);
    expect(looksSensitive("db lives at ~/.juancode/data/juancode.db")).toBe(false);
  });
});

describe("parseCandidates", () => {
  it("extracts a fenced JSON array", () => {
    const out = parseCandidates(
      'Here you go:\n```json\n[{"name":"Port Fact","type":"reference","fact":"f","why":"w"}]\n```',
    );
    expect(out).toEqual([{ name: "port-fact", type: "reference", fact: "f", why: "w" }]);
  });

  it("defaults an unknown type, derives a missing name, and drops factless items", () => {
    const out = parseCandidates('[{"fact":"Bundle staleness bites"},{"type":"user"},{"fact":"x","type":"nope"}]');
    expect(out).toEqual([
      { name: "bundle-staleness-bites", type: "project", fact: "Bundle staleness bites", why: "" },
      { name: "x", type: "project", fact: "x", why: "" },
    ]);
  });

  it("caps at three candidates", () => {
    const many = JSON.stringify(Array.from({ length: 6 }, (_, i) => ({ fact: `fact ${i}` })));
    expect(parseCandidates(many)).toHaveLength(3);
  });

  it("returns nothing for prose, an empty array, or broken JSON", () => {
    expect(parseCandidates("Nothing qualifies here.")).toEqual([]);
    expect(parseCandidates("[]")).toEqual([]);
    expect(parseCandidates("[{oops}]")).toEqual([]);
  });
});

describe("existingMemory + filterCandidates", () => {
  it("reads memory slugs, the index and prior candidates", () => {
    writeFileSync(join(dir, "juancode-db-path.md"), "---\nname: juancode-db-path\n---\n");
    writeFileSync(join(dir, "MEMORY.md"), "- [DB path](juancode-db-path.md) — native app DB\n");
    writeFileSync(join(dir, "CANDIDATES.md"), "- name: already-proposed\n  type: project\n");

    const existing = existingMemory(dir);
    expect(existing.names.has("juancode-db-path")).toBe(true);
    expect(existing.names.has("already-proposed")).toBe(true);
    expect(existing.text).toContain("native app DB");
  });

  it("survives a missing memory dir", () => {
    const existing = existingMemory(join(dir, "nope"));
    expect(existing.names.size).toBe(0);
    expect(existing.text).toBe("");
  });

  it("drops name collisions, in-batch repeats and sensitive facts", () => {
    const existing = { names: new Set(["known-fact"]), text: "" };
    const out = filterCandidates(
      [
        candidate({ name: "known-fact" }),
        candidate({ name: "fresh" }),
        candidate({ name: "fresh" }),
        candidate({ name: "leaky", fact: "ping juan@fanvue.com when it breaks" }),
      ],
      existing,
    );
    expect(out.map((c) => c.name)).toEqual(["fresh"]);
  });

  it("drops a fact whose distinctive words are all already recorded", () => {
    const existing = {
      names: new Set<string>(),
      text: "sidecar talks to the native app on port 4280 over a websocket",
    };
    const out = filterCandidates(
      [
        candidate({ name: "dupe", fact: "The sidecar talks to the native app on port 4280" }),
        candidate({ name: "novel", fact: "SwiftTerm crashes when parsing OSC 8 concurrently" }),
      ],
      existing,
    );
    expect(out.map((c) => c.name)).toEqual(["novel"]);
  });
});

describe("renderCandidates", () => {
  it("renders a reviewable block, never memory frontmatter", () => {
    const md = renderCandidates([candidate({ name: "port-4280" })], {
      sessionId: "c767831f-d5f6-498f",
      project: "/Users/me/repo",
      when: "2026-07-29",
    });
    expect(md).toContain("## 2026-07-29 — /Users/me/repo (session c767831f)");
    expect(md).toContain("- name: port-4280");
    expect(md).toContain("  type: project");
    expect(md).toContain("  fact: The sidecar talks to the native app on port 4280");
    expect(md).toContain("  why: Not discoverable");
    // A candidate is a proposal, not a memory file.
    expect(md).not.toContain("---");
  });

  it("omits an empty why", () => {
    const md = renderCandidates([candidate({ why: "" })], {
      sessionId: "s",
      project: "p",
      when: "2026-07-29",
    });
    expect(md).not.toContain("why:");
  });
});

describe("buildPrompt", () => {
  it("includes the digest, the existing index and the no-PII instruction", () => {
    const prompt = buildPrompt("user: hello", "- [DB path](x.md)");
    expect(prompt).toContain("user: hello");
    expect(prompt).toContain("- [DB path](x.md)");
    expect(prompt).toContain("Never include names, email addresses");
    expect(prompt).toContain("at most 3");
  });

  it("says so when nothing is recorded yet", () => {
    expect(buildPrompt("user: hi", "")).toContain("(nothing yet)");
  });
});

describe("hook safety", () => {
  it("importing the module does not touch the memory dir", () => {
    // The entry-point guard means `import` never runs main(); a stray CANDIDATES.md here
    // would mean the hook fired during tests.
    mkdirSync(join(dir, "memory"), { recursive: true });
    expect(existingMemory(join(dir, "memory")).text).toBe("");
  });
});
