import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import {
  claudeSource,
  closeIndex,
  getExcerpt,
  opencodeSource,
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

// ── opencode as a second source (juancode-eo4r) ─────────────────────────────
// A fake store with the columns the reader actually touches, so the test does not
// depend on a real opencode install.

type FakePart = { type: string; text?: string; tool?: string; state?: unknown; filename?: string };

function makeOpencodeDb(path: string): DatabaseSync {
  const src = new DatabaseSync(path);
  src.exec(`
    CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL);
    CREATE TABLE message (
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
      time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
    );
    CREATE TABLE part (
      id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
      time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL
    );
  `);
  return src;
}

let partSeq = 0;

function addMessage(
  src: DatabaseSync,
  opts: {
    id: string;
    session: string;
    role: "user" | "assistant";
    parts: FakePart[];
    created?: number;
    updated?: number;
    cwd?: string;
    partUpdated?: number;
  },
): void {
  const created = opts.created ?? 1_780_000_000_000;
  const updated = opts.updated ?? created;
  src
    .prepare("INSERT OR REPLACE INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)")
    .run(
      opts.id,
      opts.session,
      created,
      updated,
      JSON.stringify({ role: opts.role, ...(opts.cwd ? { path: { cwd: opts.cwd } } : {}) }),
    );
  for (const part of opts.parts) {
    partSeq += 1;
    src
      .prepare("INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)")
      .run(`prt_${partSeq}`, opts.id, opts.session, created, opts.partUpdated ?? updated, JSON.stringify(part));
  }
}

describe("opencodeSource", () => {
  let ocPath: string;
  let src: DatabaseSync;

  beforeEach(() => {
    ocPath = join(root, "opencode.db");
    src = makeOpencodeDb(ocPath);
    src.prepare("INSERT INTO session (id, directory) VALUES (?, ?)").run(
      "ses_1",
      "/Users/me/workdir/personal/juancode",
    );
  });

  afterEach(() => {
    src.close();
  });

  it("indexes opencode messages with agent provenance", () => {
    addMessage(src, {
      id: "msg_1",
      session: "ses_1",
      role: "user",
      parts: [{ type: "text", text: "which port does the dolt server use" }],
    });
    addMessage(src, {
      id: "msg_2",
      session: "ses_1",
      role: "assistant",
      cwd: "/Users/me/workdir/personal/juancode",
      parts: [
        { type: "step-start" },
        { type: "reasoning", text: "the arlingclose container already owns 3307" },
        { type: "text", text: "it listens on 3308" },
      ],
    });

    const stats = refreshIndex(db, [opencodeSource(ocPath)]);
    expect(stats.entriesAdded).toBe(2);

    const [hit] = searchTranscripts("dolt", {}, db);
    expect(hit).toMatchObject({
      agent: "opencode",
      sessionId: "ses_1",
      role: "user",
      // Falls back to session.directory when the message carries no cwd.
      project: "personal/juancode",
    });

    // opencode keeps reasoning in full, so recall reaches it.
    expect(searchTranscripts("arlingclose", {}, db)[0]?.agent).toBe("opencode");
  });

  it("skips messages with no prose and never indexes attachment data URIs", () => {
    addMessage(src, { id: "msg_1", session: "ses_1", role: "assistant", parts: [{ type: "step-finish" }] });
    addMessage(src, {
      id: "msg_2",
      session: "ses_1",
      role: "user",
      parts: [{ type: "file", filename: "screenshot.png" }],
    });
    expect(refreshIndex(db, [opencodeSource(ocPath)]).entriesAdded).toBe(1);
    expect(searchTranscripts("screenshot.png", {}, db)).toHaveLength(1);
  });

  it("refreshes incrementally on time_updated, including late parts", () => {
    addMessage(src, {
      id: "msg_1",
      session: "ses_1",
      role: "user",
      parts: [{ type: "text", text: "first opencode turn" }],
      created: 1_000,
      updated: 1_000,
    });
    expect(refreshIndex(db, [opencodeSource(ocPath)]).entriesAdded).toBe(1);
    // Nothing new: the watermark holds.
    expect(refreshIndex(db, [opencodeSource(ocPath)])).toMatchObject({ filesUpdated: 0, entriesAdded: 0 });

    addMessage(src, {
      id: "msg_2",
      session: "ses_1",
      role: "assistant",
      parts: [{ type: "text", text: "second opencode turn" }],
      created: 2_000,
      updated: 2_000,
    });
    expect(refreshIndex(db, [opencodeSource(ocPath)]).entriesAdded).toBe(1);

    // A part streamed in after its message row still pulls the message back in.
    addMessage(src, {
      id: "msg_2",
      session: "ses_1",
      role: "assistant",
      parts: [{ type: "text", text: "second opencode turn" }, { type: "text", text: "a late addendum" }],
      created: 2_000,
      updated: 2_000,
      partUpdated: 9_000,
    });
    expect(refreshIndex(db, [opencodeSource(ocPath)]).entriesAdded).toBe(1);
    // Replaced, not duplicated: the same message read twice is one row.
    expect(searchTranscripts("second", {}, db)).toHaveLength(1);
    expect(searchTranscripts("addendum", {}, db)).toHaveLength(1);
  });

  it("groups excerpt context per opencode session", () => {
    addMessage(src, { id: "m1", session: "ses_1", role: "user", parts: [{ type: "text", text: "turn one" }], created: 1 });
    addMessage(src, { id: "m2", session: "ses_1", role: "assistant", parts: [{ type: "text", text: "the needle" }], created: 2 });
    addMessage(src, { id: "m3", session: "ses_1", role: "user", parts: [{ type: "text", text: "turn three" }], created: 3 });
    src.prepare("INSERT INTO session (id, directory) VALUES (?, ?)").run("ses_2", "/Users/me/other");
    addMessage(src, { id: "m4", session: "ses_2", role: "user", parts: [{ type: "text", text: "unrelated" }], created: 4 });

    refreshIndex(db, [opencodeSource(ocPath)]);
    const [hit] = searchTranscripts("needle", {}, db);
    expect(getExcerpt(hit!.id, 5, db)?.context?.map((c) => c.text)).toEqual(["turn one", "turn three"]);
  });

  it("survives a missing opencode DB", () => {
    expect(refreshIndex(db, [opencodeSource(join(root, "absent.db"))])).toMatchObject({
      filesScanned: 0,
      entriesAdded: 0,
    });
  });

  it("never writes to the opencode DB", () => {
    addMessage(src, { id: "m1", session: "ses_1", role: "user", parts: [{ type: "text", text: "read only please" }] });
    const before = statSync(ocPath).mtimeMs;
    refreshIndex(db, [opencodeSource(ocPath)]);
    expect(searchTranscripts("read only please", {}, db)).toHaveLength(1);
    expect(statSync(ocPath).mtimeMs).toBe(before);
  });
});

describe("agent provenance and filtering", () => {
  it("tags claude entries and filters by agent, never merging across agents", () => {
    writeTranscript("-p", "s", [line("user", "the same sentence in both agents")]);
    const ocPath = join(root, "oc.db");
    const src = makeOpencodeDb(ocPath);
    src.prepare("INSERT INTO session (id, directory) VALUES (?, ?)").run("ses_1", "/Users/me/workdir/personal/juancode");
    addMessage(src, {
      id: "m1",
      session: "ses_1",
      role: "user",
      parts: [{ type: "text", text: "the same sentence in both agents" }],
    });
    src.close();

    refreshIndex(db, [claudeSource(root), opencodeSource(ocPath)]);

    // Two agents saying the same thing is a signal, so both rows survive.
    const all = searchTranscripts("sentence", {}, db);
    expect(all).toHaveLength(2);
    expect(new Set(all.map((h) => h.agent))).toEqual(new Set(["claude", "opencode"]));

    expect(searchTranscripts("sentence", { agents: ["claude"] }, db).map((h) => h.agent)).toEqual(["claude"]);
    expect(searchTranscripts("sentence", { agents: ["opencode"] }, db).map((h) => h.agent)).toEqual(["opencode"]);
    // An empty list means "no filter", not "no agents".
    expect(searchTranscripts("sentence", { agents: [] }, db)).toHaveLength(2);

    const hit = searchTranscripts("sentence", { agents: ["opencode"] }, db)[0]!;
    expect(getExcerpt(hit.id, 0, db)?.agent).toBe("opencode");
  });
});
