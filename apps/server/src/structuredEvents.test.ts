import { describe, expect, it } from "vitest";
import { recordToEvents } from "./structuredEvents.ts";

describe("recordToEvents — Claude", () => {
  it("maps a string user prompt to a user bubble", () => {
    const events = recordToEvents(
      "claude",
      { type: "user", message: { role: "user", content: "hello there" } },
      1,
    );
    expect(events).toEqual([{ id: "c1", kind: "user", text: "hello there", ts: null }]);
  });

  it("splits an assistant message into text, thinking and tool_use events", () => {
    const events = recordToEvents(
      "claude",
      {
        type: "assistant",
        timestamp: "2026-06-26T19:09:38.872Z",
        message: {
          role: "assistant",
          content: [
            { type: "thinking", thinking: "let me think", signature: "x" },
            { type: "text", text: "On it." },
            { type: "tool_use", id: "toolu_1", name: "Bash", input: { command: "ls" } },
          ],
        },
      },
      2,
    );
    expect(events).toMatchObject([
      { kind: "thinking", text: "let me think", ts: "2026-06-26T19:09:38.872Z" },
      { kind: "assistant", text: "On it." },
      { kind: "tool_use", toolName: "Bash", id: "toolu_1" },
    ]);
    expect(events[2]!.toolInput).toContain('"command": "ls"');
  });

  it("maps a tool_result user record, carrying the tool_use id and error flag", () => {
    const events = recordToEvents(
      "claude",
      {
        type: "user",
        message: {
          role: "user",
          content: [
            { type: "tool_result", tool_use_id: "toolu_1", content: "boom", is_error: true },
          ],
        },
      },
      3,
    );
    expect(events).toEqual([
      {
        id: "c3:0",
        kind: "tool_result",
        text: "boom",
        toolUseId: "toolu_1",
        isError: true,
        ts: null,
      },
    ]);
  });

  it("flattens a list-shaped tool_result content into text", () => {
    const events = recordToEvents(
      "claude",
      {
        type: "user",
        message: {
          role: "user",
          content: [
            { type: "tool_result", tool_use_id: "t", content: [{ type: "text", text: "line" }] },
          ],
        },
      },
      4,
    );
    expect(events[0]!.text).toBe("line");
    expect(events[0]!.isError).toBe(false);
  });

  it("skips sidechain (sub-agent) records and empty text blocks", () => {
    expect(
      recordToEvents(
        "claude",
        {
          type: "assistant",
          isSidechain: true,
          message: { content: [{ type: "text", text: "x" }] },
        },
        5,
      ),
    ).toEqual([]);
    expect(
      recordToEvents(
        "claude",
        { type: "assistant", message: { content: [{ type: "text", text: "   " }] } },
        6,
      ),
    ).toEqual([]);
  });

  it("ignores bookkeeping record types", () => {
    expect(recordToEvents("claude", { type: "ai-title", aiTitle: "x" }, 7)).toEqual([]);
    expect(recordToEvents("claude", { type: "file-history-snapshot" }, 8)).toEqual([]);
  });
});

describe("recordToEvents — Codex", () => {
  it("maps user and agent messages", () => {
    expect(
      recordToEvents(
        "codex",
        { type: "event_msg", payload: { type: "user_message", message: "do a thing" } },
        1,
      ),
    ).toEqual([{ id: "x1", kind: "user", text: "do a thing", ts: null }]);
    expect(
      recordToEvents(
        "codex",
        { type: "event_msg", payload: { type: "agent_message", message: "done" } },
        2,
      ),
    ).toEqual([{ id: "x2", kind: "assistant", text: "done", ts: null }]);
  });

  it("maps a function_call and its output, pairing by call_id", () => {
    const call = recordToEvents(
      "codex",
      {
        type: "response_item",
        payload: {
          type: "function_call",
          name: "exec_command",
          arguments: '{"cmd":"ls"}',
          call_id: "call_9",
        },
      },
      3,
    );
    expect(call).toMatchObject([
      { kind: "tool_use", toolName: "exec_command", toolUseId: "call_9" },
    ]);
    expect(call[0]!.toolInput).toContain('"cmd": "ls"'); // pretty-printed from the JSON string

    const out = recordToEvents(
      "codex",
      {
        type: "response_item",
        payload: { type: "function_call_output", call_id: "call_9", output: "files" },
      },
      4,
    );
    expect(out).toEqual([
      { id: "x4", kind: "tool_result", text: "files", toolUseId: "call_9", ts: null },
    ]);
  });

  it("surfaces a reasoning summary only when it has text", () => {
    expect(
      recordToEvents(
        "codex",
        { type: "response_item", payload: { type: "reasoning", summary: [] } },
        5,
      ),
    ).toEqual([]);
    expect(
      recordToEvents(
        "codex",
        {
          type: "response_item",
          payload: { type: "reasoning", summary: [{ type: "summary_text", text: "plan" }] },
        },
        6,
      ),
    ).toEqual([{ id: "x6", kind: "thinking", text: "plan", ts: null }]);
  });

  it("ignores token_count and raw role messages", () => {
    expect(
      recordToEvents("codex", { type: "event_msg", payload: { type: "token_count", info: {} } }, 7),
    ).toEqual([]);
    expect(
      recordToEvents(
        "codex",
        { type: "response_item", payload: { type: "message", role: "developer", content: [] } },
        8,
      ),
    ).toEqual([]);
  });
});
