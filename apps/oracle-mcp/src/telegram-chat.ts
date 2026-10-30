// One Oracle turn for a Telegram chat, with provider fallback (juancode-c8m).
// Claude answers first (`oracleChat`, which already retries a stale resume id fresh);
// when that turn is unusable — the CLI failed, errored, or said nothing — the same
// message goes to GPT (`codex exec`) and then Kimi (`kimi -p`). Every provider resumes
// its OWN conversation for the chat: Claude's id stays in `sessionId`, the others in
// the store's `fallbackSessions`, so a later turn on a provider continues its thread.
//
// A fallback answer reports `sessionId: null`, which the bridge treats as "leave the
// chat's Claude binding alone" — Claude resumes where it left off once it is back. The
// turns a fallback answered are not in Claude's thread; that gap is accepted, since
// ids cannot be shared between CLIs.

import {
  type FallbackProvider,
  type ProviderRun,
  PROVIDER_LABEL,
  fallbackPrompt,
  runCodex,
  runKimi,
} from "./chat-fallback.ts";
import {
  type ChatReply,
  type ChatOrigin,
  ORACLE_SYSTEM,
  oracleChat,
  oracleDir,
  originSystemPrompt,
} from "./oracle.ts";
import { getFallbackSession, setFallbackSession } from "./telegram-store.ts";

export interface TelegramChatDeps {
  claude: (text: string, sessionId: string | null, origin: ChatOrigin) => Promise<ChatReply>;
  fallbacks: readonly {
    provider: FallbackProvider;
    run: (prompt: string, resume: string | null, cwd: string) => Promise<ProviderRun>;
  }[];
  getFallbackSession: (chatId: number, provider: FallbackProvider) => Promise<string | null>;
  setFallbackSession: (chatId: number, provider: FallbackProvider, id: string) => Promise<void>;
  system: string;
  cwd: string;
}

function defaultDeps(): TelegramChatDeps {
  return {
    claude: oracleChat,
    // Claude → GPT → Kimi.
    fallbacks: [
      { provider: "codex", run: (p, r, c) => runCodex(p, r, c) },
      { provider: "kimi", run: (p, r, c) => runKimi(p, r, c) },
    ],
    getFallbackSession,
    setFallbackSession,
    system: ORACLE_SYSTEM,
    cwd: oracleDir(),
  };
}

/** A turn worth showing: Claude (or a fallback) answered, with text. */
function usable(r: ChatReply): boolean {
  return !r.isError && r.reply.trim().length > 0;
}

/** Whether a failed resume looks like the provider no longer knowing the conversation,
 *  which is the only failure a fresh thread can fix (a usage limit or a timeout would
 *  fail again, and a second 180s attempt is not free). */
export function looksLikeStaleSession(message: string): boolean {
  return /\b(session|thread|conversation|rollout)\b.*\b(not found|no such|unknown|invalid|missing|does not exist)\b|\b(no|unknown|invalid) (session|thread|conversation)\b|no rollout found|could not (find|resume)/i.test(
    message,
  );
}

function oneLine(s: string, max = 200): string {
  const line =
    s
      .trim()
      .split(/\r?\n/)
      .find((l) => l.trim()) ?? "no output";
  return line.length > max ? `${line.slice(0, max - 1)}…` : line;
}

export async function telegramChat(
  text: string,
  claudeSessionId: string | null,
  chatId: number,
  deps: TelegramChatDeps = defaultDeps(),
): Promise<ChatReply> {
  const origin: ChatOrigin = { telegramChatId: chatId };
  const first = await deps.claude(text, claudeSessionId, origin);
  if (usable(first)) return first;

  const failed: string[] = [PROVIDER_LABEL.claude];
  const failures: string[] = [`${PROVIDER_LABEL.claude}: ${oneLine(first.reply)}`];
  const prompt = fallbackPrompt(
    [deps.system, originSystemPrompt(origin)].filter(Boolean).join("\n"),
    text,
  );

  for (const { provider, run } of deps.fallbacks) {
    const resume = await deps.getFallbackSession(chatId, provider);
    let result = await run(prompt, resume, deps.cwd);
    if (!result.ok && resume && looksLikeStaleSession(result.reply)) {
      result = await run(prompt, null, deps.cwd);
    }
    if (result.ok) {
      if (result.sessionId) await deps.setFallbackSession(chatId, provider, result.sessionId);
      return {
        reply: `↪ ${PROVIDER_LABEL[provider]} answered (${failed.join(" and ")} unavailable)\n\n${result.reply.trim()}`,
        isError: false,
        sessionId: null,
      };
    }
    failed.push(PROVIDER_LABEL[provider]);
    failures.push(`${PROVIDER_LABEL[provider]}: ${oneLine(result.reply)}`);
  }

  return {
    reply: `Oracle is unavailable on every provider.\n${failures.map((f) => `• ${f}`).join("\n")}`,
    isError: true,
    sessionId: null,
  };
}
