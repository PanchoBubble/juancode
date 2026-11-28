// One streaming-endpoint turn answered by codex instead of claude (juancode-3aq8.9).
// `codex exec` is not incremental, so the whole reply goes out as a single delta. The
// session id the client holds is then a codex thread id, resumed on the next turn.

import { fallbackPrompt, runCodex } from "./chat-fallback.ts";
import { ORACLE_SYSTEM, oracleDir, type ChatStreamDone } from "./oracle.ts";
import { looksLikeStaleSession } from "./telegram-chat.ts";

// shortcut: an aborted request does not kill the codex child (bounded by its 180s timeout), thread via captureProcess if that bites.
export async function codexChatStream(
  text: string,
  sessionId: string | null,
  onDelta: (text: string) => void,
): Promise<ChatStreamDone> {
  const prompt = fallbackPrompt(ORACLE_SYSTEM, text);
  const cwd = oracleDir();
  let run = await runCodex(prompt, sessionId, cwd);
  if (!run.ok && sessionId && looksLikeStaleSession(run.reply)) {
    run = await runCodex(prompt, null, cwd);
  }
  onDelta(run.reply);
  return { sessionId: run.sessionId ?? (run.ok ? null : sessionId), isError: !run.ok };
}
