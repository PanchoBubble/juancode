import { describe, expect, it, vi } from "vitest";
import {
  chunkMessage,
  handleUpdate,
  isAllowed,
  parseAllowedUserIds,
  parseTextMessage,
  readTelegramConfig,
  type TelegramDeps,
  type TgUpdate,
} from "./telegram.ts";
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
    expect(parseTextMessage(u)).toEqual({ chatId: 9, userId: 5, messageId: 42, text: "hi" });
  });
  it("returns a null messageId when message_id is absent", () => {
    const u: TgUpdate = { update_id: 1, message: { chat: { id: 9 }, from: { id: 5 }, text: "hi" } };
    expect(parseTextMessage(u)).toEqual({ chatId: 9, userId: 5, messageId: null, text: "hi" });
  });
  it("ignores non-text / malformed updates", () => {
    expect(parseTextMessage({ update_id: 1 })).toBeNull();
    expect(parseTextMessage({ update_id: 1, message: { chat: { id: 9 }, from: { id: 5 } } })).toBeNull();
    expect(
      parseTextMessage({ update_id: 1, message: { chat: { id: 9 }, from: { id: 5 }, text: "  " } }),
    ).toBeNull();
  });
});

function makeDeps(overrides: Partial<TelegramDeps> = {}): TelegramDeps {
  return {
    chat: vi.fn(async (): Promise<ChatReply> => ({ reply: "ok", isError: false, sessionId: "s1" })),
    getSession: vi.fn(async () => null),
    setSession: vi.fn(async () => {}),
    clearSession: vi.fn(async () => {}),
    send: vi.fn(async () => {}),
    typing: vi.fn(async () => {}),
    react: vi.fn(async () => {}),
    ...overrides,
  };
}

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
