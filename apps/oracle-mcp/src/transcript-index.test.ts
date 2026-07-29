import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  closeIndex,
  getExcerpt,
  openIndex,
  parseTranscriptLine,
  refreshIndex,
  searchTranscripts,
  toMatchExpression,
} from "./transcript-index.ts";

let root: string;
let db: ReturnType<typeof openIndex>;

/** Build one transcript line in the shape Claude Code writes. */
function line(
  role: "user" | "assistant",
  content: unknown,
  over: Record<string, unknown> = {},
): string {
  return `${JSON.stringify({
    type: role,
    sessionId: "sess-1",
    cwd: "/Users/me/workdir/personal/juancode",
    gitBranch: "main",
    timestamp: "2026-07-20T10:00:00.000Z",
    message: { role, content },
    ...over,
  })}\n`;
}

function writeTranscript(project: string, session: string, lines: string[]): string {
  const dir = join(root, project);
  mkdirSync(dir, { recursive: true });
  const path = join(dir, `${session}.jsonl`);
  writeFileSync(path, lines.join(""));
  return path;
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "juancode-transcripts-"));
  db = openIndex(":memory:");
});

afterEach(() => {
  closeIndex();
  rmSync(root, { recursive: true, force: true });
});

describe("parseTranscriptLine", () => {
  it("keeps user prose", () => {
    const entry = parseTranscriptLine(line("user", "the dolt server listens on 3308"));
    expect(entry).toMatchObject({
      role: "user",
      sessionId: "sess-1",
      branch: "main",
      text: "the dolt server listens on 3308",
    });
  });

  it("flattens assistant text and tool_use blocks, skipping thinking", () => {
    const entry = parseTranscriptLine(
      line("assistant", [
        { type: "thinking", thinking: "secret reasoning", signature: "CAISgg" },
        { type: "text", text: "Running the migration" },
        { type: "tool_use", name: "Bash", input: { command: "bd sync" } },
      ]),
    );
    expect(entry?.text).toContain("Running the migration");
    expect(entry?.text).toContain("[Bash]");
    expect(entry?.text).toContain("bd sync");
    expect(entry?.text).not.toContain("secret reasoning");
  });

  it("reads nested tool_result content", () => {
    const entry = parseTranscriptLine(
      line("user", [{ type: "tool_result", content: [{ type: "text", text: "42 tests passed" }] }]),
    );
    expect(entry?.text).toBe("42 tests passed");
  });

  it("ignores non-message lines, blank bodies and malformed JSON", () => {
    expect(parseTranscriptLine('{"type":"mode","mode":"normal"}')).toBeUndefined();
    expect(parseTranscriptLine(line("user", ""))).toBeUndefined();
    expect(parseTranscriptLine(line("assistant", [{ type: "thinking", thinking: "x" }]))).toBeUndefined();
    expect(parseTranscriptLine("{not json")).toBeUndefined();
  });

  it("caps very long entries", () => {
    const entry = parseTranscriptLine(line("user", "x".repeat(10_000)));
    expect(entry?.text.length).toBe(4000);
  });
});

describe("toMatchExpression", () => {
  it("quotes each term so punctuation is not read as FTS syntax", () => {
    expect(toMatchExpression("dolt port")).toBe('"dolt" AND "port"');
    expect(toMatchExpression("~/.juancode/data")).toBe('"~/.juancode/data"');
    expect(toMatchExpression("   ")).toBe("");
  });
});

describe("refreshIndex + searchTranscripts", () => {
  it("indexes transcripts and returns compact hits", () => {
    writeTranscript("-Users-me-juancode", "sess-1", [
      line("user", "why does the dolt server use port 3308"),
      line("assistant", [{ type: "text", text: "because 3307 is taken by arlingclose" }]),
    ]);

    const stats = refreshIndex(db, root);
    expect(stats.entriesAdded).toBe(2);

    const hits = searchTranscripts("dolt", {}, db);
    expect(hits).toHaveLength(1);
    expect(hits[0]!).toMatchObject({
      sessionId: "sess-1",
      role: "user",
      branch: "main",
      // Shortened cwd: enough to tell projects apart, cheap in tokens.
      project: "personal/juancode",
    });
    expect(hits[0]!.snippet).toContain("dolt");
    // A hit is an index entry, not a body dump.
    expect(hits[0]!.snippet.length).toBeLessThan(200);
  });

  it("requires every term to match", () => {
    writeTranscript("-p", "s", [line("user", "alpha only"), line("user", "alpha and beta")]);
    refreshIndex(db, root);
    expect(searchTranscripts("alpha", {}, db)).toHaveLength(2);
    expect(searchTranscripts("alpha beta", {}, db)).toHaveLength(1);
  });

  it("filters by project and since", () => {
    writeTranscript("-a", "s1", [line("user", "shared keyword here")]);
    writeTranscript("-b", "s2", [
      line("user", "shared keyword here", {
        sessionId: "s2",
        cwd: "/Users/me/workdir/fanvue/horizon",
        timestamp: "2026-01-01T00:00:00.000Z",
      }),
    ]);
    refreshIndex(db, root);

    expect(searchTranscripts("keyword", {}, db)).toHaveLength(2);
    expect(searchTranscripts("keyword", { project: "juancode" }, db)).toHaveLength(1);
    expect(searchTranscripts("keyword", { project: "horizon" }, db)[0]!.sessionId).toBe("s2");
    expect(searchTranscripts("keyword", { since: "2026-07-01T00:00:00.000Z" }, db)).toHaveLength(1);
  });

  it("honours limit", () => {
    writeTranscript("-p", "s", Array.from({ length: 10 }, (_, i) => line("user", `repeated token ${i}`)));
    refreshIndex(db, root);
    expect(searchTranscripts("repeated", { limit: 3 }, db)).toHaveLength(3);
  });

  it("returns nothing for an empty query", () => {
    writeTranscript("-p", "s", [line("user", "anything")]);
    refreshIndex(db, root);
    expect(searchTranscripts("  ", {}, db)).toEqual([]);
  });
});

describe("incremental refresh", () => {
  it("only reads bytes appended since the last pass", () => {
    const path = writeTranscript("-p", "s", [line("user", "first turn about widgets")]);
    expect(refreshIndex(db, root).entriesAdded).toBe(1);

    // Untouched file: nothing re-read.
    expect(refreshIndex(db, root)).toMatchObject({ filesUpdated: 0, entriesAdded: 0 });

    appendFileSync(path, line("user", "second turn about gadgets"));
    const stats = refreshIndex(db, root);
    expect(stats).toMatchObject({ filesUpdated: 1, entriesAdded: 1 });
    expect(searchTranscripts("gadgets", {}, db)).toHaveLength(1);
    expect(searchTranscripts("widgets", {}, db)).toHaveLength(1);
  });

  it("leaves a half-written trailing line for the next pass", () => {
    const path = writeTranscript("-p", "s", [line("user", "complete line")]);
    appendFileSync(path, '{"type":"user","message":{"role":"user","content":"trunc');
    expect(refreshIndex(db, root).entriesAdded).toBe(1);

    // Completing the line makes it indexable without losing the earlier entry.
    appendFileSync(path, 'ated but now finished"}}\n');
    expect(refreshIndex(db, root).entriesAdded).toBe(1);
    expect(searchTranscripts("finished", {}, db)).toHaveLength(1);
    expect(searchTranscripts("complete", {}, db)).toHaveLength(1);
  });

  it("reindexes a file that shrank (rewritten on resume)", () => {
    const path = writeTranscript("-p", "s", [
      line("user", "original alpha content"),
      line("user", "original beta content"),
    ]);
    refreshIndex(db, root);
    expect(searchTranscripts("alpha", {}, db)).toHaveLength(1);

    writeFileSync(path, line("user", "rewritten gamma"));
    refreshIndex(db, root);
    expect(searchTranscripts("alpha", {}, db)).toEqual([]);
    expect(searchTranscripts("beta", {}, db)).toEqual([]);
    expect(searchTranscripts("gamma", {}, db)).toHaveLength(1);
  });

  it("survives a missing transcripts root", () => {
    expect(refreshIndex(db, join(root, "nope"))).toMatchObject({ filesScanned: 0 });
  });
});

describe("getExcerpt", () => {
  it("returns the full text for one id", () => {
    writeTranscript("-p", "s", [line("user", "the full body of this turn is longer than a snippet")]);
    refreshIndex(db, root);
    const [hit] = searchTranscripts("snippet", {}, db);
    const excerpt = getExcerpt(hit!.id, 0, db);
    expect(excerpt?.text).toBe("the full body of this turn is longer than a snippet");
    expect(excerpt?.context).toBeUndefined();
  });

  it("includes surrounding turns when asked", () => {
    writeTranscript("-p", "s", [
      line("user", "turn one"),
      line("assistant", [{ type: "text", text: "turn two" }]),
      line("user", "the needle"),
      line("assistant", [{ type: "text", text: "turn four" }]),
    ]);
    refreshIndex(db, root);
    const [hit] = searchTranscripts("needle", {}, db);
    const excerpt = getExcerpt(hit!.id, 1, db);
    expect(excerpt?.context?.map((c) => c.text)).toEqual(["turn two", "turn four"]);
  });

  it("finds neighbours across refresh passes", () => {
    const path = writeTranscript("-p", "s", [line("user", "earlier turn")]);
    refreshIndex(db, root);
    // A second file bumps the global rowid counter, so ids are no longer contiguous.
    writeTranscript("-other", "s2", [line("user", "unrelated", { sessionId: "s2" })]);
    refreshIndex(db, root);
    appendFileSync(path, line("user", "the needle"));
    refreshIndex(db, root);

    const [hit] = searchTranscripts("needle", {}, db);
    const excerpt = getExcerpt(hit!.id, 5, db);
    expect(excerpt?.context?.map((c) => c.text)).toEqual(["earlier turn"]);
  });

  it("returns undefined for an unknown id", () => {
    expect(getExcerpt(9999, 0, db)).toBeUndefined();
  });
});
