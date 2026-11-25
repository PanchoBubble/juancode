// chain_ask (juancode-8oa5.1): an agent's one explicit way to ask the human. The
// question is a chain handoff with target Human — the daemon's existing record
// (pending -> acknowledged -> closed), not a new entity — plus one Telegram ping whose
// reply routes back into the asking session. The plain-text needs-input heuristic stays
// the net for agents that never call this.

import { randomUUID } from "node:crypto";
import { resolveDispatchOrigin } from "./dispatch-origin.ts";
import {
  chainForSession,
  createHandoff,
  supportsHandoffs,
  type HandoffInput,
  type HandoffResult,
} from "./native-events.ts";
import { notifyOracleText } from "./telegram.ts";

export interface AskInput {
  /** The asking session's own id; inferred only for an unambiguous busy Oracle. */
  sessionId?: string;
  question: string;
  options: string[];
  recommended: string;
  blocked: string;
}

export interface AskDeps {
  origin: (given: string | undefined) => Promise<string | null>;
  chainSlugOf: (sessionId: string) => string | null;
  supported: () => boolean;
  createHandoff: (handoff: HandoffInput) => Promise<HandoffResult>;
  /** Ping the human; a reply to the ping answers `handoffId`. */
  notify: (sessionId: string, text: string, handoffId: string) => Promise<{ chatIds: number[] }>;
  newId: () => string;
}

export const defaultAskDeps: AskDeps = {
  origin: (given) => resolveDispatchOrigin(given),
  chainSlugOf: (id) => chainForSession(id)?.slug ?? null,
  supported: supportsHandoffs,
  createHandoff,
  notify: (sessionId, text, handoffId) =>
    notifyOracleText(
      sessionId,
      text,
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      handoffId,
    ),
  newId: randomUUID,
};

/** The question as the human reads it, in the handoff summary and on the phone. */
export function askText(a: AskInput): string {
  const options = a.options.map(
    (o, i) => `${i + 1}. ${o}${o === a.recommended ? " (recommended)" : ""}`,
  );
  return [
    `❓ ${a.question}`,
    ...options,
    ...(a.options.includes(a.recommended) ? [] : [`Recommended: ${a.recommended}`]),
    `Blocked: ${a.blocked}`,
  ].join("\n");
}

/** Record the question and ping the human once. Throws, having changed nothing, when
 *  the caller is not a session in a chain; a failed ping is reported, not thrown, since
 *  the pending handoff is already the durable record. */
export async function askHuman(input: AskInput, deps: AskDeps = defaultAskDeps): Promise<string> {
  const asker = await deps.origin(input.sessionId);
  if (!asker) {
    throw new Error("Supply your session id; the caller could not be identified unambiguously.");
  }
  const text = askText(input);
  const { id, chainSlug, sent } = await handToHuman(asker, text, deps.newId(), deps);
  return `Question recorded for the human (handoff ${id}, chain ${chainSlug}); ${
    sent ? `pinged ${sent} Telegram chat${sent === 1 ? "" : "s"}` : "no Telegram chat was pinged"
  }. Stop and wait: the answer arrives as your next input.`;
}

/** The human-targeted handoff from `source`'s chain plus one best-effort ping. A
 *  repeated `id` with the same summary is the same handoff to the daemon, so a retry
 *  after a crash records nothing twice. Throws, having changed nothing, without a chain. */
export async function handToHuman(
  source: string,
  text: string,
  id: string,
  deps: Pick<AskDeps, "chainSlugOf" | "supported" | "createHandoff" | "notify"> = defaultAskDeps,
): Promise<{ id: string; chainSlug: string; sent: number }> {
  const chainSlug = deps.chainSlugOf(source);
  if (!chainSlug) {
    throw new Error(
      "This session is not in a chain, so there is nobody to route the question to. Ask in your normal reply instead.",
    );
  }
  if (!deps.supported()) {
    throw new Error("This core does not record handoffs (no chainHandoffs capability).");
  }
  const made = await deps.createHandoff({
    id,
    chainSlug,
    source: { kind: "session", sessionId: source },
    target: { kind: "human" },
    summary: text,
  });
  if (!made.ok) throw new Error(`Could not record the question (${made.error ?? "unknown"}).`);
  const sent = await deps.notify(source, text, id).then(
    (r) => r.chatIds.length,
    () => 0,
  );
  return { id, chainSlug, sent };
}
