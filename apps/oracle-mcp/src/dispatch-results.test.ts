import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { appendFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  consumeQueuedDispatch,
  markQueuedDispatch,
  parseDispatchResultLine,
  startDispatchResultsWatcher,
  type DispatchResultRecord,
} from "./dispatch-results.ts";

describe("parseDispatchResultLine", () => {
  it("parses a full Swift OracleDispatchResult line", () => {
    const line = JSON.stringify({
      dispatchId: "d-1",
      project: "/abs/repo",
      ok: false,
      error: '"/abs/repo" is not an existing directory',
      at: 1234,
    });
    expect(parseDispatchResultLine(line)).toEqual({
      dispatchId: "d-1",
      project: "/abs/repo",
      ok: false,
      sessionId: null,
      error: '"/abs/repo" is not an existing directory',
      at: 1234,
    });
  });

  it("normalizes omitted optionals to null (agent-written dispatches have no id)", () => {
    const line = JSON.stringify({ project: "/p", ok: true, sessionId: "s-1", at: 1 });
    expect(parseDispatchResultLine(line)).toEqual({
      dispatchId: null,
      project: "/p",
      ok: true,
      sessionId: "s-1",
      error: null,
      at: 1,
    });
  });

  it("rejects malformed / foreign lines", () => {
    expect(parseDispatchResultLine("not json")).toBeNull();
    expect(parseDispatchResultLine("null")).toBeNull();
    expect(parseDispatchResultLine(JSON.stringify({ ok: true }))).toBeNull();
  });
});

describe("queued-dispatch memory", () => {
  it("confirms each queued id exactly once", () => {
    markQueuedDispatch("q-1");
    expect(consumeQueuedDispatch("q-1")).toBe(true);
    expect(consumeQueuedDispatch("q-1")).toBe(false);
    expect(consumeQueuedDispatch("never-queued")).toBe(false);
    expect(consumeQueuedDispatch(null)).toBe(false);
  });
});

describe("startDispatchResultsWatcher", () => {
  let dir: string;
  let stop: (() => void) | null = null;
  const prev = process.env.JUANCODE_ORACLE_DIR;
  const POLL_MS = 20;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oracle-results-test-"));
    process.env.JUANCODE_ORACLE_DIR = dir;
  });

  afterEach(() => {
    stop?.();
    stop = null;
    if (prev === undefined) delete process.env.JUANCODE_ORACLE_DIR;
    else process.env.JUANCODE_ORACLE_DIR = prev;
    rmSync(dir, { recursive: true, force: true });
  });

  const file = () => join(dir, "dispatch-results.jsonl");
  const record = (dispatchId: string, ok: boolean) =>
    JSON.stringify({ dispatchId, project: "/p", ok, at: 1 }) + "\n";

  /** Wait until `predicate` holds (or a generous deadline passes). */
  const waitFor = async (predicate: () => boolean): Promise<void> => {
    const deadline = Date.now() + 2000;
    while (!predicate() && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, POLL_MS));
    }
  };
  const settle = () => new Promise((r) => setTimeout(r, POLL_MS * 4));

  it("emits only records appended after the watcher started, in order", async () => {
    writeFileSync(file(), record("old", true)); // pre-existing → never emitted
    const seen: DispatchResultRecord[] = [];
    stop = startDispatchResultsWatcher((r) => seen.push(r), POLL_MS);
    await settle(); // let the first poll prime the offset to EOF

    appendFileSync(file(), record("a", false));
    appendFileSync(file(), record("b", true));
    await waitFor(() => seen.length >= 2);
    expect(seen.map((r) => r.dispatchId)).toEqual(["a", "b"]);

    appendFileSync(file(), record("c", false));
    await waitFor(() => seen.length >= 3);
    expect(seen.map((r) => r.dispatchId)).toEqual(["a", "b", "c"]);
  });

  it("leaves a torn trailing line for the next poll", async () => {
    const seen: DispatchResultRecord[] = [];
    stop = startDispatchResultsWatcher((r) => seen.push(r), POLL_MS);
    await settle();

    const whole = record("done", true);
    appendFileSync(file(), whole.slice(0, 10)); // torn write, no newline yet
    await settle();
    expect(seen).toEqual([]);

    appendFileSync(file(), whole.slice(10));
    await waitFor(() => seen.length >= 1);
    expect(seen.map((r) => r.dispatchId)).toEqual(["done"]);
  });

  it("tolerates a missing file, then picks up its first lines", async () => {
    const seen: DispatchResultRecord[] = [];
    stop = startDispatchResultsWatcher((r) => seen.push(r), POLL_MS);
    await settle(); // file doesn't exist yet

    writeFileSync(file(), record("first", true));
    await waitFor(() => seen.length >= 1);
    expect(seen.map((r) => r.dispatchId)).toEqual(["first"]);
  });
});
