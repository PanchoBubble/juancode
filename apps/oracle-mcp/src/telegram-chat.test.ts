import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { chmodSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  codexArgs,
  kimiArgs,
  parseCodexRun,
  parseKimiRun,
  runCodex,
  runKimi,
  type ProviderRun,
} from "./chat-fallback.ts";
import { looksLikeStaleSession, telegramChat, type TelegramChatDeps } from "./telegram-chat.ts";
import {
  getFallbackSession,
  getTelegramSession,
  setFallbackSession,
  setTelegramSession,
} from "./telegram-store.ts";

const ok = (reply: string, sessionId: string | null = null): ProviderRun => ({
  ok: true,
  reply,
  sessionId,
});
const bad = (reply: string): ProviderRun => ({ ok: false, reply, sessionId: null });

function makeDeps(over: {
  claude?: TelegramChatDeps["claude"];
  codex?: TelegramChatDeps["fallbacks"][number]["run"];
  kimi?: TelegramChatDeps["fallbacks"][number]["run"];
}) {
  const saved = new Map<string, string>();
  const calls: string[] = [];
  const deps: TelegramChatDeps = {
    claude: over.claude ?? (async () => ({ reply: "claude down", isError: true, sessionId: null })),
    fallbacks: [
      {
        provider: "codex",
        run: async (p, r, c) => {
          calls.push("codex");
          return (over.codex ?? (async () => bad("codex down")))(p, r, c);
        },
      },
      {
        provider: "kimi",
        run: async (p, r, c) => {
          calls.push("kimi");
          return (over.kimi ?? (async () => bad("kimi down")))(p, r, c);
        },
      },
    ],
    getFallbackSession: async (chat, provider) => saved.get(`${chat}:${provider}`) ?? null,
    setFallbackSession: async (chat, provider, id) => void saved.set(`${chat}:${provider}`, id),
    system: "SYSTEM",
    cwd: "/control",
  };
  return { deps, saved, calls };
}

describe("telegramChat fallback order", () => {
  it("answers from Claude and never touches the fallbacks when Claude is usable", async () => {
    const { deps, calls } = makeDeps({
      claude: async () => ({ reply: "hi", isError: false, sessionId: "c-1" }),
    });
    expect(await telegramChat("yo", null, 7, deps)).toEqual({
      reply: "hi",
      isError: false,
      sessionId: "c-1",
    });
    expect(calls).toEqual([]);
  });

  it.each([
    ["an error result", { reply: "You've hit your limit", isError: true, sessionId: null }],
    ["an empty reply", { reply: "  ", isError: false, sessionId: "c-1" }],
  ])("falls back to GPT on %s, leaving the Claude binding alone", async (_n, claudeReply) => {
    const { deps, saved, calls } = makeDeps({
      claude: async () => claudeReply,
      codex: async (prompt, resume, cwd) => {
        expect(resume).toBeNull();
        expect(cwd).toBe("/control");
        expect(prompt).toContain("SYSTEM");
        expect(prompt).toContain("Telegram chat 7");
        expect(prompt).toContain("do it");
        return ok("done by gpt", "thread-1");
      },
    });
    const r = await telegramChat("do it", "c-old", 7, deps);
    expect(calls).toEqual(["codex"]);
    expect(r.isError).toBe(false);
    expect(r.sessionId).toBeNull();
    expect(r.reply).toContain("GPT (Codex) answered (Claude unavailable)");
    expect(r.reply).toContain("done by gpt");
    expect(saved.get("7:codex")).toBe("thread-1");
  });

  it("goes on to Kimi when Claude and GPT both fail", async () => {
    const { deps, saved, calls } = makeDeps({
      kimi: async () => ok("kimi here", "session_k"),
    });
    const r = await telegramChat("q", null, 7, deps);
    expect(calls).toEqual(["codex", "kimi"]);
    expect(r.reply).toContain("Kimi answered (Claude and GPT (Codex) unavailable)");
    expect(saved.get("7:kimi")).toBe("session_k");
    expect(saved.has("7:codex")).toBe(false);
  });

  it("reports every provider's failure when none answers", async () => {
    const { deps } = makeDeps({
      codex: async () => bad("codex: quota"),
      kimi: async () => bad("429 limit\nsee log"),
    });
    const r = await telegramChat("q", null, 7, deps);
    expect(r.isError).toBe(true);
    expect(r.sessionId).toBeNull();
    expect(r.reply).toContain("• Claude: claude down");
    expect(r.reply).toContain("• GPT (Codex): codex: quota");
    expect(r.reply).toContain("• Kimi: 429 limit");
    expect(r.reply).not.toContain("see log");
  });
});

describe("telegramChat per-provider continuity", () => {
  it("resumes each provider's own conversation id for the chat", async () => {
    const seen: (string | null)[] = [];
    const { deps, saved } = makeDeps({
      codex: async (_p, resume) => {
        seen.push(resume);
        return ok("again", "thread-1");
      },
    });
    saved.set("7:codex", "thread-1");
    saved.set("8:codex", "thread-other-chat");
    await telegramChat("q", null, 7, deps);
    expect(seen).toEqual(["thread-1"]);
  });

  it("retries fresh when a resume fails because the conversation is gone", async () => {
    const seen: (string | null)[] = [];
    const { deps, saved } = makeDeps({
      codex: async (_p, resume) => {
        seen.push(resume);
        return resume ? bad("thread not found: thread-old") : ok("fresh", "thread-new");
      },
    });
    saved.set("7:codex", "thread-old");
    const r = await telegramChat("q", null, 7, deps);
    expect(seen).toEqual(["thread-old", null]);
    expect(r.reply).toContain("fresh");
    expect(saved.get("7:codex")).toBe("thread-new");
  });

  it("does not burn a second attempt on a usage limit", async () => {
    const seen: (string | null)[] = [];
    const { deps, saved } = makeDeps({
      codex: async (_p, resume) => {
        seen.push(resume);
        return bad("429 usage limit reached");
      },
      kimi: async () => ok("kimi", "k"),
    });
    saved.set("7:codex", "thread-1");
    await telegramChat("q", null, 7, deps);
    expect(seen).toEqual(["thread-1"]);
    expect(saved.get("7:codex")).toBe("thread-1");
  });

  it("recognises stale-conversation errors and nothing broader", () => {
    expect(looksLikeStaleSession("thread not found: x")).toBe(true);
    expect(looksLikeStaleSession("No conversation found with session ID")).toBe(true);
    expect(looksLikeStaleSession("session does not exist")).toBe(true);
    expect(looksLikeStaleSession("429 You've reached your 5-hour usage limit")).toBe(false);
    expect(looksLikeStaleSession("codex exited 1")).toBe(false);
  });
});

describe("CLI arguments", () => {
  it("starts and resumes codex through exec with its JSON stream and no config overrides", () => {
    const flags = ["--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox"];
    expect(codexArgs("PROMPT", null)).toEqual(["exec", ...flags, "PROMPT"]);
    expect(codexArgs("PROMPT", "thr")).toEqual(["exec", "resume", ...flags, "thr", "PROMPT"]);
    // No -C / -c / --profile: the user's config is the one that applies.
    for (const a of [codexArgs("P", null), codexArgs("P", "t")]) {
      expect(a).not.toContain("-c");
      expect(a).not.toContain("--profile");
    }
  });

  it("runs kimi in print mode, resuming with -S and passing no mode flag print mode rejects", () => {
    expect(kimiArgs("PROMPT", null)).toEqual(["-p", "PROMPT", "--output-format", "stream-json"]);
    expect(kimiArgs("PROMPT", "session_x")).toEqual([
      "-S",
      "session_x",
      "-p",
      "PROMPT",
      "--output-format",
      "stream-json",
    ]);
    for (const a of [kimiArgs("P", null), kimiArgs("P", "s")]) {
      expect(a).not.toContain("--yolo");
      expect(a).not.toContain("--auto");
    }
  });
});

describe("provider output", () => {
  it("takes codex's last agent message and its thread id", () => {
    const out = [
      '{"type":"thread.started","thread_id":"thr-9"}',
      '{"type":"turn.started"}',
      '{"type":"item.completed","item":{"id":"i0","type":"reasoning","text":"hmm"}}',
      '{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"working"}}',
      '{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"final answer"}}',
      '{"type":"turn.completed","usage":{}}',
    ].join("\n");
    expect(parseCodexRun(0, out, "")).toEqual({
      ok: true,
      reply: "final answer",
      sessionId: "thr-9",
    });
  });

  it("treats a failed codex turn as unusable even with exit 0 or earlier text", () => {
    const out = [
      '{"type":"thread.started","thread_id":"thr-9"}',
      '{"type":"item.completed","item":{"type":"agent_message","text":"partial"}}',
      '{"type":"turn.failed","error":{"message":"You exceeded your current quota"}}',
    ].join("\n");
    const r = parseCodexRun(0, out, "");
    expect(r.ok).toBe(false);
    expect(r.reply).toBe("You exceeded your current quota");
    expect(parseCodexRun(1, "", "boom\nmore").reply).toBe("boom");
    expect(parseCodexRun(0, '{"type":"thread.started","thread_id":"t"}', "").ok).toBe(false);
  });

  it("surfaces kimi's real usage-limit failure (exit 1, only a meta line on stdout)", () => {
    const stdout = '{"role":"meta","type":"system.version","version":"2.4.0"}\n';
    const stderr =
      "error: failed to run prompt: provider.api_error: 429 You've reached your 5-hour usage limit.\nSee log: /x/kimi-code.log\n";
    const r = parseKimiRun(1, stdout, stderr);
    expect(r.ok).toBe(false);
    expect(r.reply).toMatch(/^failed to run prompt: provider\.api_error: 429/);
  });

  it("takes kimi's last text-bearing assistant message, skipping tool-call steps", () => {
    const out = [
      '{"role":"meta","type":"system.version","version":"2.4.0"}',
      '{"role":"assistant","content":"let me look","tool_calls":[{"id":"t1"}]}',
      '{"role":"tool","content":"result"}',
      '{"role":"assistant","content":[{"type":"think","think":"..."},{"type":"text","text":"the answer"}]}',
    ].join("\n");
    expect(parseKimiRun(0, out, "")).toEqual({ ok: true, reply: "the answer", sessionId: null });
    expect(parseKimiRun(0, '{"role":"meta"}', "").ok).toBe(false);
  });
});

describe("real process runs", () => {
  let dir: string;
  let env: NodeJS.ProcessEnv;
  const bin = (name: string, body: string) => {
    const path = join(dir, name);
    writeFileSync(path, `#!/bin/sh\n${body}\n`);
    chmodSync(path, 0o755);
    return path;
  };

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oracle-fallback-"));
    env = { PATH: process.env.PATH, HOME: "/home/inherited", MY_MARKER: "kept" };
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("launches codex with the inherited environment, in the control dir", async () => {
    env.JUANCODE_CODEX_BIN = bin(
      "codex",
      `printf '%s\\n' "$@" > "${dir}/argv"; echo "$HOME|$MY_MARKER|\${CODEX_HOME-unset}|$(pwd -P)" > "${dir}/env"
echo '{"type":"thread.started","thread_id":"thr-1"}'
echo '{"type":"item.completed","item":{"type":"agent_message","text":"pong"}}'`,
    );
    const cwd = mkdtempSync(join(tmpdir(), "oracle-cwd-"));
    try {
      const r = await runCodex("PROMPT", "thr-0", cwd, env);
      expect(r).toEqual({ ok: true, reply: "pong", sessionId: "thr-1" });
      expect(readFileSync(join(dir, "argv"), "utf8").trim().split("\n")).toEqual([
        "exec",
        "resume",
        "--json",
        "--skip-git-repo-check",
        "--dangerously-bypass-approvals-and-sandbox",
        "thr-0",
        "PROMPT",
      ]);
      const [home, marker, codexHome, pwd] = readFileSync(join(dir, "env"), "utf8")
        .trim()
        .split("|");
      expect([home, marker, codexHome]).toEqual(["/home/inherited", "kept", "unset"]);
      expect(pwd).toBe(realpathSync(cwd));
    } finally {
      rmSync(cwd, { recursive: true, force: true });
    }
  });

  it("reports a missing codex binary as a failed run, not a throw", async () => {
    env.JUANCODE_CODEX_BIN = join(dir, "does-not-exist");
    const r = await runCodex("P", null, dir, env);
    expect(r.ok).toBe(false);
    expect(r.reply).toContain("failed to launch");
  });

  it("learns a fresh kimi run's session id from its index, and keeps it on resume", async () => {
    const home = join(dir, "kimi-home");
    const work = mkdtempSync(join(tmpdir(), "oracle-kimi-cwd-"));
    env.KIMI_CODE_HOME = home;
    env.JUANCODE_KIMI_BIN = bin(
      "kimi",
      `mkdir -p "${home}"; printf '%s\\n' "$@" > "${dir}/argv"
echo '{"sessionId":"session_new","sessionDir":"x","workDir":"'"$(pwd -P)"'"}' >> "${home}/session_index.jsonl"
echo '{"role":"meta","type":"system.version","version":"2.4.0"}'
echo '{"role":"assistant","content":"kimi pong"}'`,
    );
    try {
      const fresh = await runKimi("PROMPT", null, work, env);
      expect(fresh).toEqual({ ok: true, reply: "kimi pong", sessionId: "session_new" });
      expect(readFileSync(join(dir, "argv"), "utf8").trim().split("\n")).toEqual([
        "-p",
        "PROMPT",
        "--output-format",
        "stream-json",
      ]);
      const resumed = await runKimi("PROMPT", "session_old", work, env);
      expect(resumed.sessionId).toBe("session_old");
      expect(readFileSync(join(dir, "argv"), "utf8").trim().split("\n").slice(0, 2)).toEqual([
        "-S",
        "session_old",
      ]);
    } finally {
      rmSync(work, { recursive: true, force: true });
    }
  });

  it("does not adopt another directory's kimi session", async () => {
    const home = join(dir, "kimi-home");
    env.KIMI_CODE_HOME = home;
    env.JUANCODE_KIMI_BIN = bin(
      "kimi",
      `mkdir -p "${home}"
echo '{"sessionId":"session_elsewhere","sessionDir":"x","workDir":"/some/other/project"}' >> "${home}/session_index.jsonl"
echo '{"role":"assistant","content":"ok"}'`,
    );
    const r = await runKimi("P", null, dir, env);
    expect(r.ok).toBe(true);
    expect(r.sessionId).toBeNull();
  });

  it("fails a kimi run that hits its usage limit", async () => {
    env.JUANCODE_KIMI_BIN = bin(
      "kimi",
      `echo '{"role":"meta","type":"system.version","version":"2.4.0"}'
echo "error: failed to run prompt: provider.api_error: 429 usage limit" >&2
exit 1`,
    );
    const r = await runKimi("P", "session_x", dir, env);
    expect(r.ok).toBe(false);
    expect(r.reply).toContain("429 usage limit");
    expect(r.sessionId).toBe("session_x");
  });
});

describe("telegram store keeps provider ids apart", () => {
  let dir: string;
  const prev = process.env.JUANCODE_ORACLE_DIR;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oracle-telegram-fb-"));
    process.env.JUANCODE_ORACLE_DIR = dir;
  });
  afterEach(() => {
    vi.restoreAllMocks();
    if (prev === undefined) delete process.env.JUANCODE_ORACLE_DIR;
    else process.env.JUANCODE_ORACLE_DIR = prev;
    rmSync(dir, { recursive: true, force: true });
  });

  it("rebinding Claude's id does not drop a fallback id, and vice versa", async () => {
    await setFallbackSession(7, "codex", "thr-1", 1);
    expect(await getTelegramSession(7)).toBeNull();
    await setTelegramSession(7, "claude-1", 2);
    await setFallbackSession(7, "kimi", "session_k", 3);
    await setTelegramSession(7, "claude-2", 4);
    expect(await getTelegramSession(7)).toBe("claude-2");
    expect(await getFallbackSession(7, "codex")).toBe("thr-1");
    expect(await getFallbackSession(7, "kimi")).toBe("session_k");
    expect(await getFallbackSession(8, "codex")).toBeNull();
  });
});
