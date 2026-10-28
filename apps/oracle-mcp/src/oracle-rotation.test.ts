import { describe, expect, it } from "vitest";
import {
  IDLE_ROTATE_MIN_TOKENS,
  IDLE_ROTATE_MS,
  MAX_CONTEXT_TOKENS,
  decideResume,
  summarizeTranscript,
  transcriptPath,
} from "./oracle-rotation.ts";
import { oracleModelArgs } from "./oracle.ts";

const line = (o: unknown) => JSON.stringify(o);

function transcript(contextTokens: number): string {
  return [
    line({ type: "user", message: { role: "user", content: "dispatch juancode-abc" } }),
    line({
      type: "assistant",
      message: {
        role: "assistant",
        content: [
          { type: "text", text: "Dispatched juancode-abc." },
          { type: "tool_use", id: "t1", name: "Bash", input: {} },
        ],
        usage: { input_tokens: 4, cache_read_input_tokens: contextTokens - 4 },
      },
    }),
    line({
      type: "user",
      message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1" }] },
    }),
    line({ type: "user", isMeta: true, message: { role: "user", content: "<meta>" } }),
    "not json",
  ].join("\n");
}

describe("summarizeTranscript", () => {
  it("keeps the last request's context size and only plain-text messages", () => {
    const s = summarizeTranscript(transcript(90_000));
    expect(s.contextTokens).toBe(90_000);
    expect(s.messages).toEqual([
      { role: "user", text: "dispatch juancode-abc" },
      { role: "assistant", text: "Dispatched juancode-abc." },
    ]);
  });
});

describe("decideResume", () => {
  it("resumes a warm conversation", () => {
    expect(decideResume(60_000, summarizeTranscript(transcript(100_000)))).toEqual({
      action: "resume",
    });
  });

  it("resumes a small conversation even after a long idle gap", () => {
    const s = summarizeTranscript(transcript(IDLE_ROTATE_MIN_TOKENS - 1));
    expect(decideResume(IDLE_ROTATE_MS * 3, s).action).toBe("resume");
  });

  it("starts fresh with a carry-over when an idle resume would rebuild a large cache", () => {
    const d = decideResume(IDLE_ROTATE_MS, summarizeTranscript(transcript(IDLE_ROTATE_MIN_TOKENS)));
    expect(d.action).toBe("fresh");
    if (d.action !== "fresh") return;
    expect(d.carry).toContain("User: dispatch juancode-abc");
    expect(d.carry).toContain("Oracle: Dispatched juancode-abc.");
    expect(d.carry.endsWith("New message follows.]\n\n")).toBe(true);
  });

  it("starts fresh past the context cap however recent the last turn", () => {
    expect(decideResume(0, summarizeTranscript(transcript(MAX_CONTEXT_TOKENS))).action).toBe(
      "fresh",
    );
  });
});

describe("transcriptPath", () => {
  it("matches Claude Code's project-dir slug", () => {
    expect(transcriptPath("/Users/juan/.juancode/oracle", "abc", "/h")).toBe(
      "/h/.claude/projects/-Users-juan--juancode-oracle/abc.jsonl",
    );
  });
});

describe("oracleModelArgs", () => {
  it("runs Sonnet at high effort unless overridden", () => {
    expect(oracleModelArgs({})).toEqual(["--model", "sonnet", "--effort", "high"]);
    expect(oracleModelArgs({ JUANCODE_ORACLE_MODEL: " opus ", JUANCODE_ORACLE_EFFORT: "xhigh" })).toEqual(
      ["--model", "opus", "--effort", "xhigh"],
    );
    expect(
      oracleModelArgs({ JUANCODE_ORACLE_MODEL: "default", JUANCODE_ORACLE_EFFORT: "default" }),
    ).toEqual([]);
  });
});
