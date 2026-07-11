import { describe, expect, it, vi } from "vitest";
import {
  chunkMessage,
  handleUpdate,
  isAllowed,
  newBridgeState,
  notifySessionEvent,
  parseAllowedUserIds,
  parseCallbackQuery,
  parseTextMessage,
  parseVoiceMessage,
  readTelegramConfig,
  startDispatchResultRelay,
  type TelegramDeps,
  type TgUpdate,
} from "./telegram.ts";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { markQueuedDispatch, type DispatchResultRecord } from "./dispatch-results.ts";
import type { SessionSummary } from "./telegram-format.ts";
import type { ChatReply } from "./oracle.ts";

describe("readTelegramConfig", () => {
  it("returns null without a token", () => {
    expect(readTelegramConfig({})).toBeNull();
    expect(readTelegramConfig({ TELEGRAM_BOT_TOKEN: "  " })).toBeNull();
  });

  it("parses token + allowlist", () => {
    const cfg = readTelegramConfig({ TELEGRAM_BOT_TOKEN: "tok", ALLOWED_USER_IDS: "1, 2 3" });
    expect(cfg?.token).toBe("tok");
    expect([...(cfg?.allowedUserIds ?? [])]).toEqual([1, 2, 3]);
  });
});

describe("parseAllowedUserIds", () => {
  it("handles blanks, commas, spaces, and non-numerics", () => {
    expect([...parseAllowedUserIds(undefined)]).toEqual([]);
    expect([...parseAllowedUserIds("5547517536")]).toEqual([5547517536]);
    expect([...parseAllowedUserIds("1,, 2 ,abc, 3")]).toEqual([1, 2, 3]);
  });
});

describe("isAllowed", () => {
  it("denies everyone when the allowlist is empty", () => {
    expect(isAllowed(1, new Set())).toBe(false);
  });
  it("allows only listed ids", () => {
    const set = new Set([5]);
    expect(isAllowed(5, set)).toBe(true);
    expect(isAllowed(6, set)).toBe(false);
  });
});

describe("chunkMessage", () => {
  it("keeps short text as a single chunk", () => {
    expect(chunkMessage("hello")).toEqual(["hello"]);
  });
  it("returns one chunk for empty text", () => {
    expect(chunkMessage("")).toEqual([""]);
  });
  it("splits on newline boundaries under the limit", () => {
    const chunks = chunkMessage("aaa\nbbb\nccc", 7);
    expect(chunks.every((c) => c.length <= 7)).toBe(true);
    expect(chunks.join("\n")).toBe("aaa\nbbb\nccc");
  });
  it("hard-splits a single oversized line", () => {
    const chunks = chunkMessage("x".repeat(25), 10);
    expect(chunks).toEqual(["x".repeat(10), "x".repeat(10), "x".repeat(5)]);
  });
});

describe("parseTextMessage", () => {
  it("extracts chatId, userId, messageId, trimmed text", () => {
    const u: TgUpdate = {
      update_id: 1,
      message: { message_id: 42, chat: { id: 9 }, from: { id: 5 }, text: " hi " },
    };
    expect(parseTextMessage(u)).toEqual({
      chatId: 9,
      userId: 5,
      messageId: 42,
      replyTo: null,
      text: "hi",
    });
  });
  it("returns a null messageId when message_id is absent", () => {
    const u: TgUpdate = { update_id: 1, message: { chat: { id: 9 }, from: { id: 5 }, text: "hi" } };
    expect(parseTextMessage(u)).toEqual({
      chatId: 9,
      userId: 5,
      messageId: null,
      replyTo: null,
      text: "hi",
    });
  });
  it("captures the replied-to message id", () => {
    const u: TgUpdate = {
      update_id: 1,
      message: {
        message_id: 42,
        chat: { id: 9 },
        from: { id: 5 },
        text: "yes",
        reply_to_message: { message_id: 33 },
      },
    };
    expect(parseTextMessage(u)?.replyTo).toBe(33);
  });
  it("ignores non-text / malformed updates", () => {
    expect(parseTextMessage({ update_id: 1 })).toBeNull();
    expect(parseTextMessage({ update_id: 1, message: { chat: { id: 9 }, from: { id: 5 } } })).toBeNull();
    expect(
      parseTextMessage({ update_id: 1, message: { chat: { id: 9 }, from: { id: 5 }, text: "  " } }),
    ).toBeNull();
  });
});

const SESSIONS: SessionSummary[] = [
  {
    id: "aaaa-1111",
    provider: "claude",
    cwd: "/Users/juan/workdir/juancode",
    title: "fix tests",
    status: "running",
    archived: false,
    updatedAt: 2000,
  },
  {
    id: "bbbb-2222",
    provider: "codex",
    cwd: "/Users/juan/workdir/t3code",
    title: "refactor auth",
    status: "running",
    archived: false,
    updatedAt: 1000,
  },
];

function makeDeps(overrides: Partial<TelegramDeps> = {}): TelegramDeps {
  return {
    chat: vi.fn(async (): Promise<ChatReply> => ({ reply: "ok", isError: false, sessionId: "s1" })),
    getSession: vi.fn(async () => null),
    setSession: vi.fn(async () => {}),
    clearSession: vi.fn(async () => {}),
    send: vi.fn(async () => 900),
    typing: vi.fn(async () => {}),
    react: vi.fn(async () => {}),
    answerCallback: vi.fn(async () => {}),
    sessions: vi.fn(async () => SESSIONS),
    observers: {
      list: vi.fn(async () => [] as string[]),
      add: vi.fn(async () => {}),
      remove: vi.fn(async () => 1),
      chatsFor: vi.fn(async () => [] as number[]),
    },
    outbound: {
      record: vi.fn(async () => {}),
      lookup: vi.fn(async () => null),
    },
    deliver: vi.fn(async () => {}),
    queue: vi.fn(async () => {}),
    transcribe: vi.fn(async () => "transcribed text"),
    ...overrides,
  };
}

const voiceMsg = (
  userId: number,
  fileId: string,
  { chatId = 100, messageId = 7, duration = 3 }: { chatId?: number; messageId?: number; duration?: number } = {},
): TgUpdate => ({
  update_id: 1,
  message: {
    message_id: messageId,
    chat: { id: chatId },
    from: { id: userId },
    voice: { file_id: fileId, mime_type: "audio/ogg", duration },
  },
});

const msg = (userId: number, text: string, chatId = 100, messageId = 7): TgUpdate => ({
  update_id: 1,
  message: { message_id: messageId, chat: { id: chatId }, from: { id: userId }, text },
});

describe("handleUpdate", () => {
  const allowed = new Set([5]);

  it("ignores messages from non-allowed users (no chat, no send)", async () => {
    const deps = makeDeps();
    await handleUpdate(msg(999, "hello"), allowed, deps);
    expect(deps.chat).not.toHaveBeenCalled();
    expect(deps.send).not.toHaveBeenCalled();
  });

  it("routes an allowed message through the shared backend and persists the session", async () => {
    const deps = makeDeps({
      getSession: vi.fn(async () => "prev-session"),
      chat: vi.fn(async () => ({ reply: "the answer", isError: false, sessionId: "new-session" })),
    });
    await handleUpdate(msg(5, "what's up"), allowed, deps);
    expect(deps.chat).toHaveBeenCalledWith("what's up", "prev-session");
    expect(deps.setSession).toHaveBeenCalledWith(100, "new-session");
    expect(deps.send).toHaveBeenCalledWith(100, "the answer");
  });

  it("shows a 👀 reaction + typing before working, then clears the reaction", async () => {
    const deps = makeDeps();
    await handleUpdate(msg(5, "what's up"), allowed, deps);
    // 👀 reaction set on the user's message, then cleared (null) when done.
    expect(deps.react).toHaveBeenNthCalledWith(1, 100, 7, "👀");
    expect(deps.react).toHaveBeenLastCalledWith(100, 7, null);
    expect(deps.typing).toHaveBeenCalledWith(100);
  });

  it("does not react when the update has no message id", async () => {
    const deps = makeDeps();
    const update: TgUpdate = {
      update_id: 1,
      message: { chat: { id: 100 }, from: { id: 5 }, text: "hi" },
    };
    await handleUpdate(update, allowed, deps);
    expect(deps.react).not.toHaveBeenCalled();
    expect(deps.typing).toHaveBeenCalledWith(100);
    expect(deps.send).toHaveBeenCalled();
  });

  it("does not show the working indicator for /new or /start", async () => {
    const deps = makeDeps();
    await handleUpdate(msg(5, "/new"), allowed, deps);
    expect(deps.react).not.toHaveBeenCalled();
    expect(deps.typing).not.toHaveBeenCalled();
  });

  it("/new clears the chat's session and confirms", async () => {
    const deps = makeDeps();
    await handleUpdate(msg(5, "/new"), allowed, deps);
    expect(deps.clearSession).toHaveBeenCalledWith(100);
    expect(deps.chat).not.toHaveBeenCalled();
    expect(deps.send).toHaveBeenCalledTimes(1);
  });

  it("/start clears the session and greets", async () => {
    const deps = makeDeps();
    await handleUpdate(msg(5, "/start"), allowed, deps);
    expect(deps.clearSession).toHaveBeenCalledWith(100);
    expect(deps.chat).not.toHaveBeenCalled();
  });

  it("does not persist a session when the backend returns none", async () => {
    const deps = makeDeps({
      chat: vi.fn(async () => ({ reply: "hi", isError: false, sessionId: null })),
    });
    await handleUpdate(msg(5, "hello"), allowed, deps);
    expect(deps.setSession).not.toHaveBeenCalled();
  });

  it("prefixes backend errors with a warning marker", async () => {
    const deps = makeDeps({
      chat: vi.fn(async () => ({ reply: "boom", isError: true, sessionId: null })),
    });
    await handleUpdate(msg(5, "hello"), allowed, deps);
    expect(deps.send).toHaveBeenCalledWith(100, "⚠️ boom");
  });

  it("chunks long replies into multiple sends", async () => {
    const deps = makeDeps({
      chat: vi.fn(async () => ({ reply: "y".repeat(9000), isError: false, sessionId: null })),
    });
    await handleUpdate(msg(5, "hello"), allowed, deps);
    expect((deps.send as ReturnType<typeof vi.fn>).mock.calls.length).toBeGreaterThan(1);
  });
});

describe("parseCallbackQuery", () => {
  it("extracts id, chat, user, and data", () => {
    const u: TgUpdate = {
      update_id: 1,
      callback_query: {
        id: "cb1",
        from: { id: 5 },
        message: { message_id: 3, chat: { id: 100 } },
        data: "o:aaaa-1111",
      },
    };
    expect(parseCallbackQuery(u)).toEqual({
      callbackId: "cb1",
      chatId: 100,
      userId: 5,
      data: "o:aaaa-1111",
    });
  });
  it("returns null for malformed callbacks", () => {
    expect(parseCallbackQuery({ update_id: 1 })).toBeNull();
    expect(parseCallbackQuery({ update_id: 1, callback_query: { id: "x" } })).toBeNull();
  });
});

describe("session commands", () => {
  const allowed = new Set([5]);

  it("/sessions lists sessions with state + observe buttons and remembers the order", async () => {
    const deps = makeDeps();
    const state = newBridgeState();
    state.activity.set("aaaa-1111", "waiting_input");
    await handleUpdate(msg(5, "/sessions"), allowed, deps, state);
    const [chatId, text, opts] = (deps.send as ReturnType<typeof vi.fn>).mock.calls[0]!;
    expect(chatId).toBe(100);
    expect(text).toContain("1. 🟡 fix tests");
    expect(text).toContain("juancode · claude · waiting for input");
    expect(text).toContain("2.");
    expect(opts.keyboard[0][0]).toEqual({ text: "👁1", data: "o:aaaa-1111" });
    expect(state.lastList.get(100)).toEqual(["aaaa-1111", "bbbb-2222"]);
    expect(deps.chat).not.toHaveBeenCalled();
  });

  it("/sessions reports the native app being down instead of throwing", async () => {
    const deps = makeDeps({
      sessions: vi.fn(async () => {
        throw new Error("Couldn't reach the juancode app");
      }),
    });
    await handleUpdate(msg(5, "/sessions"), allowed, deps);
    expect(deps.send).toHaveBeenCalledWith(100, expect.stringContaining("⚠️"));
  });

  it("/observe <n> resolves against the last printed list and subscribes", async () => {
    const deps = makeDeps();
    const state = newBridgeState();
    state.lastList.set(100, ["bbbb-2222", "aaaa-1111"]);
    await handleUpdate(msg(5, "/observe 2"), allowed, deps, state);
    expect(deps.observers.add).toHaveBeenCalledWith(100, "aaaa-1111");
    expect(deps.send).toHaveBeenCalledWith(100, expect.stringContaining("fix tests"));
  });

  it("/observe with an id prefix works without a prior list", async () => {
    const deps = makeDeps();
    await handleUpdate(msg(5, "/observe bbbb"), allowed, deps);
    expect(deps.observers.add).toHaveBeenCalledWith(100, "bbbb-2222");
  });

  it("/observe with no match explains itself", async () => {
    const deps = makeDeps();
    await handleUpdate(msg(5, "/observe zzz"), allowed, deps);
    expect(deps.observers.add).not.toHaveBeenCalled();
    expect(deps.send).toHaveBeenCalledWith(100, expect.stringContaining("No session matches"));
  });

  it("/unobserve with no arg drops every subscription", async () => {
    const deps = makeDeps({
      observers: {
        list: vi.fn(async () => ["aaaa-1111", "bbbb-2222"]),
        add: vi.fn(async () => {}),
        remove: vi.fn(async () => 2),
        chatsFor: vi.fn(async () => []),
      },
    });
    await handleUpdate(msg(5, "/unobserve"), allowed, deps);
    expect(deps.observers.remove).toHaveBeenCalledWith(100);
    expect(deps.send).toHaveBeenCalledWith(100, expect.stringContaining("2 session(s)"));
  });

  it("/status shows observed sessions and flags gone ones", async () => {
    const deps = makeDeps({
      observers: {
        list: vi.fn(async () => ["aaaa-1111", "dead-9999"]),
        add: vi.fn(async () => {}),
        remove: vi.fn(async () => 1),
        chatsFor: vi.fn(async () => []),
      },
    });
    await handleUpdate(msg(5, "/status"), allowed, deps);
    const [, text, opts] = (deps.send as ReturnType<typeof vi.fn>).mock.calls[0]!;
    expect(text).toContain("fix tests");
    expect(text).toContain("gone");
    expect(opts.keyboard[0]).toHaveLength(2);
  });

  it("observe button press subscribes and acks the callback", async () => {
    const deps = makeDeps();
    const update: TgUpdate = {
      update_id: 1,
      callback_query: {
        id: "cb1",
        from: { id: 5 },
        message: { message_id: 3, chat: { id: 100 } },
        data: "o:aaaa-1111",
      },
    };
    await handleUpdate(update, allowed, deps);
    expect(deps.observers.add).toHaveBeenCalledWith(100, "aaaa-1111");
    expect(deps.answerCallback).toHaveBeenCalledWith("cb1", expect.stringContaining("Observing"));
  });

  it("callback from a non-allowed user is acked but ignored", async () => {
    const deps = makeDeps();
    const update: TgUpdate = {
      update_id: 1,
      callback_query: {
        id: "cb1",
        from: { id: 999 },
        message: { message_id: 3, chat: { id: 100 } },
        data: "o:aaaa-1111",
      },
    };
    await handleUpdate(update, allowed, deps);
    expect(deps.observers.add).not.toHaveBeenCalled();
    expect(deps.answerCallback).toHaveBeenCalledWith("cb1");
  });
});

describe("reply-to-notification routing", () => {
  const allowed = new Set([5]);
  const replyMsg = (text: string, replyTo: number): TgUpdate => ({
    update_id: 1,
    message: {
      message_id: 8,
      chat: { id: 100 },
      from: { id: 5 },
      text,
      reply_to_message: { message_id: replyTo },
    },
  });

  it("delivers straight into the session when it is not busy, and confirms", async () => {
    const deps = makeDeps({
      outbound: {
        record: vi.fn(async () => {}),
        lookup: vi.fn(async () => ({ sessionId: "aaaa-1111", title: "fix tests" })),
      },
    });
    await handleUpdate(replyMsg("yes, option 2", 33), allowed, deps);
    expect(deps.deliver).toHaveBeenCalledWith("aaaa-1111", "yes, option 2");
    expect(deps.queue).not.toHaveBeenCalled();
    expect(deps.chat).not.toHaveBeenCalled();
    expect(deps.send).toHaveBeenCalledWith(100, expect.stringContaining("✅ Sent to “fix tests”"));
    // The confirmation itself is recorded so replying to it chains.
    expect(deps.outbound.record).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 100, messageId: 900, sessionId: "aaaa-1111" }),
    );
  });

  it("queues instead when the session is busy", async () => {
    const deps = makeDeps({
      outbound: {
        record: vi.fn(async () => {}),
        lookup: vi.fn(async () => ({ sessionId: "aaaa-1111", title: "fix tests" })),
      },
    });
    const state = newBridgeState();
    state.activity.set("aaaa-1111", "busy");
    await handleUpdate(replyMsg("also do X", 33), allowed, deps, state);
    expect(deps.queue).toHaveBeenCalledWith("aaaa-1111", ["also do X"]);
    expect(deps.deliver).not.toHaveBeenCalled();
    expect(deps.send).toHaveBeenCalledWith(100, expect.stringContaining("📥 Queued"));
  });

  it("falls back to the Oracle chat when the replied-to message is not ours", async () => {
    const deps = makeDeps();
    await handleUpdate(replyMsg("hello", 12345), allowed, deps);
    expect(deps.deliver).not.toHaveBeenCalled();
    expect(deps.chat).toHaveBeenCalledWith("hello", null);
  });

  it("reports a delivery failure instead of throwing", async () => {
    const deps = makeDeps({
      outbound: {
        record: vi.fn(async () => {}),
        lookup: vi.fn(async () => ({ sessionId: "aaaa-1111", title: "fix tests" })),
      },
      deliver: vi.fn(async () => {
        throw new Error("native app is down");
      }),
    });
    await handleUpdate(replyMsg("yes", 33), allowed, deps);
    expect(deps.send).toHaveBeenCalledWith(100, expect.stringContaining("⚠️ Couldn't deliver"));
    expect(deps.chat).not.toHaveBeenCalled();
  });
});

describe("notifySessionEvent", () => {
  const observers = (chats: number[]) => ({
    list: vi.fn(async () => [] as string[]),
    add: vi.fn(async () => {}),
    remove: vi.fn(async () => 1),
    chatsFor: vi.fn(async () => chats),
  });

  it("notifies observer chats on a needs-input transition and records the outbound ref", async () => {
    const deps = makeDeps({ observers: observers([100, 200]) });
    const state = newBridgeState();
    await notifySessionEvent(
      { sessionId: "aaaa-1111", state: "waiting_input", notify: true },
      deps,
      state,
    );
    const sends = (deps.send as ReturnType<typeof vi.fn>).mock.calls;
    expect(sends).toHaveLength(2);
    expect(sends[0]![1]).toContain("🟡 fix tests — juancode");
    expect(sends[0]![1]).toContain("needs your input");
    expect(deps.outbound.record).toHaveBeenCalledWith(
      expect.objectContaining({ chatId: 100, messageId: 900, sessionId: "aaaa-1111" }),
    );
    expect(state.activity.get("aaaa-1111")).toBe("waiting_input");
  });

  it("stays silent on non-notify transitions but still tracks activity", async () => {
    const deps = makeDeps({ observers: observers([100]) });
    const state = newBridgeState();
    await notifySessionEvent({ sessionId: "aaaa-1111", state: "busy", notify: false }, deps, state);
    expect(deps.send).not.toHaveBeenCalled();
    expect(state.activity.get("aaaa-1111")).toBe("busy");
  });

  it("stays silent when nobody observes the session", async () => {
    const deps = makeDeps();
    await notifySessionEvent(
      { sessionId: "aaaa-1111", state: "waiting_input", notify: true },
      deps,
      newBridgeState(),
    );
    expect(deps.send).not.toHaveBeenCalled();
  });

  it("de-dupes an identical consecutive notification per chat, and resets on a new kind", async () => {
    const deps = makeDeps({ observers: observers([100]) });
    const state = newBridgeState();
    const waiting = { sessionId: "aaaa-1111", state: "waiting_input" as const, notify: true };
    await notifySessionEvent(waiting, deps, state);
    await notifySessionEvent(waiting, deps, state);
    expect(deps.send).toHaveBeenCalledTimes(1);
    await notifySessionEvent({ sessionId: "aaaa-1111", state: "idle", notify: true }, deps, state);
    expect(deps.send).toHaveBeenCalledTimes(2);
    await notifySessionEvent(waiting, deps, state);
    expect(deps.send).toHaveBeenCalledTimes(3);
  });

  it("includes the change badge in a finished ping when the turn left changes", async () => {
    const deps = makeDeps({ observers: observers([100]) });
    await notifySessionEvent(
      {
        sessionId: "aaaa-1111",
        state: "idle",
        notify: true,
        changes: { files: 3, additions: 120, deletions: 44 },
      },
      deps,
      newBridgeState(),
    );
    expect(deps.send).toHaveBeenCalledWith(
      100,
      expect.stringContaining("finished its turn, 3 files changed (+120/−44)"),
    );
  });

  it("omits the badge when there is no rollup, and never badges needs-input", async () => {
    const deps = makeDeps({ observers: observers([100]) });
    const state = newBridgeState();
    await notifySessionEvent({ sessionId: "aaaa-1111", state: "idle", notify: true }, deps, state);
    await notifySessionEvent(
      {
        sessionId: "aaaa-1111",
        state: "waiting_input",
        notify: true,
        changes: { files: 2, additions: 5, deletions: 1 },
      },
      deps,
      state,
    );
    const sends = (deps.send as ReturnType<typeof vi.fn>).mock.calls;
    expect(sends).toHaveLength(2);
    expect(sends[0]![1]).toContain("finished its turn\n");
    expect(sends[1]![1]).toContain("needs your input\n");
    expect(sends[1]![1]).not.toContain("files changed");
  });

  it("falls back to the id slice when the native list is unreachable", async () => {
    const deps = makeDeps({
      observers: observers([100]),
      sessions: vi.fn(async () => {
        throw new Error("down");
      }),
    });
    await notifySessionEvent(
      { sessionId: "aaaa-1111", state: "idle", notify: true },
      deps,
      newBridgeState(),
    );
    expect(deps.send).toHaveBeenCalledWith(100, expect.stringContaining("aaaa-111"));
  });
});

describe("parseVoiceMessage", () => {
  it("parses a voice note", () => {
    const u: TgUpdate = {
      update_id: 1,
      message: { message_id: 42, chat: { id: 9 }, from: { id: 5 }, voice: { file_id: "F1", duration: 4 } },
    };
    expect(parseVoiceMessage(u)).toEqual({
      chatId: 9,
      userId: 5,
      messageId: 42,
      fileId: "F1",
      durationSec: 4,
    });
  });

  it("parses an audio file the same as a voice note", () => {
    const u: TgUpdate = {
      update_id: 1,
      message: { chat: { id: 9 }, from: { id: 5 }, audio: { file_id: "A1" } },
    };
    expect(parseVoiceMessage(u)).toEqual({
      chatId: 9,
      userId: 5,
      messageId: null,
      fileId: "A1",
      durationSec: null,
    });
  });

  it("returns null when there is no voice/audio attachment", () => {
    expect(parseVoiceMessage({ update_id: 1 })).toBeNull();
    expect(
      parseVoiceMessage({ update_id: 1, message: { chat: { id: 9 }, from: { id: 5 }, text: "hi" } }),
    ).toBeNull();
    // A voice object without a file_id is not actionable.
    expect(
      parseVoiceMessage({ update_id: 1, message: { chat: { id: 9 }, from: { id: 5 }, voice: {} } }),
    ).toBeNull();
  });
});

describe("handleUpdate — voice messages", () => {
  const allowed = new Set([5]);

  it("transcribes, echoes the transcript, and routes it to the backend", async () => {
    const deps = makeDeps({
      transcribe: vi.fn(async () => "  what's the deploy status  "),
      chat: vi.fn(async () => ({ reply: "all green", isError: false, sessionId: "sid" })),
    });
    await handleUpdate(voiceMsg(5, "FILE123"), allowed, deps);
    expect(deps.transcribe).toHaveBeenCalledWith("FILE123");
    // Transcript echoed with a mic marker, then the real reply.
    expect(deps.send).toHaveBeenNthCalledWith(1, 100, "🎙️ what's the deploy status");
    expect(deps.chat).toHaveBeenCalledWith("what's the deploy status", null);
    expect(deps.setSession).toHaveBeenCalledWith(100, "sid");
    expect(deps.send).toHaveBeenLastCalledWith(100, "all green");
  });

  it("shows the working indicator and clears it", async () => {
    const deps = makeDeps();
    await handleUpdate(voiceMsg(5, "F"), allowed, deps);
    expect(deps.react).toHaveBeenNthCalledWith(1, 100, 7, "👀");
    expect(deps.react).toHaveBeenLastCalledWith(100, 7, null);
  });

  it("ignores voice notes from non-allowed users without transcribing", async () => {
    const deps = makeDeps();
    await handleUpdate(voiceMsg(999, "F"), allowed, deps);
    expect(deps.transcribe).not.toHaveBeenCalled();
    expect(deps.chat).not.toHaveBeenCalled();
    expect(deps.send).not.toHaveBeenCalled();
  });

  it("replies clearly when transcription fails and does not call the backend", async () => {
    const deps = makeDeps({
      transcribe: vi.fn(async () => {
        throw new Error("whisper exploded");
      }),
    });
    await handleUpdate(voiceMsg(5, "F"), allowed, deps);
    expect(deps.chat).not.toHaveBeenCalled();
    expect(deps.send).toHaveBeenCalledTimes(1);
    expect(deps.send).toHaveBeenCalledWith(100, expect.stringMatching(/Couldn't transcribe/));
    // Indicator still cleared on the error path.
    expect(deps.react).toHaveBeenLastCalledWith(100, 7, null);
  });

  it("replies clearly when the transcript is empty", async () => {
    const deps = makeDeps({ transcribe: vi.fn(async () => "   ") });
    await handleUpdate(voiceMsg(5, "F"), allowed, deps);
    expect(deps.chat).not.toHaveBeenCalled();
    expect(deps.send).toHaveBeenCalledWith(100, expect.stringMatching(/couldn't make out/i));
  });

  it("rejects an over-long note before downloading it", async () => {
    const deps = makeDeps();
    await handleUpdate(voiceMsg(5, "F", { duration: 601 }), allowed, deps);
    expect(deps.transcribe).not.toHaveBeenCalled();
    expect(deps.send).toHaveBeenCalledWith(100, expect.stringMatching(/too long/i));
  });
});

describe("startDispatchResultRelay", () => {
  const flush = () => new Promise((r) => setTimeout(r, 10));

  it("is a no-op without a bot token", () => {
    expect(startDispatchResultRelay(null)).toBeNull();
  });

  it("relays failures to the observer chats and skips foreign successes", async () => {
    const prevDir = process.env.JUANCODE_ORACLE_DIR;
    const prevIds = process.env.ALLOWED_USER_IDS;
    process.env.JUANCODE_ORACLE_DIR = mkdtempSync(join(tmpdir(), "oracle-relay-test-"));
    process.env.ALLOWED_USER_IDS = "7";
    try {
      let emit: ((r: DispatchResultRecord) => void) | null = null;
      const stopped = vi.fn();
      const send = vi.fn(async (_chatId: number, _text: string) => null);
      const stop = startDispatchResultRelay(
        { token: "t", allowedUserIds: new Set([7]) },
        (onResult) => {
          emit = onResult;
          return stopped;
        },
        send,
      );
      expect(stop).not.toBeNull();
      expect(emit).not.toBeNull();

      // A failure is always relayed.
      emit!({ dispatchId: "d-1", project: "/x/proj", ok: false, sessionId: null,
              error: "bad path", at: 1 });
      await flush();
      expect(send).toHaveBeenCalledTimes(1);
      expect(send.mock.calls[0]![0]).toBe(7);
      expect(send.mock.calls[0]![1]).toContain("bad path");

      // A success this sidecar did NOT queue is not relayed (already acked live).
      emit!({ dispatchId: "d-2", project: "/x/proj", ok: true, sessionId: "s-1",
              error: null, at: 2 });
      await flush();
      expect(send).toHaveBeenCalledTimes(1);

      // A success for a dispatch queued here IS relayed as a start confirmation.
      markQueuedDispatch("d-3");
      emit!({ dispatchId: "d-3", project: "/x/proj", ok: true, sessionId: "s-2",
              error: null, at: 3 });
      await flush();
      expect(send).toHaveBeenCalledTimes(2);
      expect(send.mock.calls[1]![1]).toContain("s-2");

      stop!();
      expect(stopped).toHaveBeenCalled();
    } finally {
      rmSync(process.env.JUANCODE_ORACLE_DIR!, { recursive: true, force: true });
      if (prevDir === undefined) delete process.env.JUANCODE_ORACLE_DIR;
      else process.env.JUANCODE_ORACLE_DIR = prevDir;
      if (prevIds === undefined) delete process.env.ALLOWED_USER_IDS;
      else process.env.ALLOWED_USER_IDS = prevIds;
    }
  });
});
