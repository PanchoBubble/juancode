// chain_handoff / chain_handoff_ack / chain_handoff_close (juancode-4t49): an agent's
// way to pass work to another session in its chain, take responsibility for a handoff
// addressed to it, and close one with evidence. Same record as chain_ask (which is the
// human-targeted case); the daemon owns the state machine and the refusals, these only
// identify the caller and check it is a party to the handoff.

import { randomUUID } from "node:crypto";
import { resolveDispatchOrigin } from "./dispatch-origin.ts";
import {
  acknowledgeHandoff,
  chainForSession,
  closeHandoff,
  createHandoff,
  handoffs,
  supportsHandoffs,
  type Handoff,
  type HandoffInput,
  type HandoffResult,
} from "./native-events.ts";

export interface HandoffDeps {
  origin: (given: string | undefined) => Promise<string | null>;
  chainSlugOf: (sessionId: string) => string | null;
  supported: () => boolean;
  find: (handoffId: string) => Handoff | null;
  create: (handoff: HandoffInput) => Promise<HandoffResult>;
  acknowledge: (handoffId: string) => Promise<HandoffResult>;
  close: (handoffId: string, reason: string) => Promise<HandoffResult>;
  newId: () => string;
}

export const defaultHandoffDeps: HandoffDeps = {
  origin: (given) => resolveDispatchOrigin(given),
  chainSlugOf: (id) => chainForSession(id)?.slug ?? null,
  supported: supportsHandoffs,
  find: (id) => handoffs()?.find((h) => h.id === id) ?? null,
  create: createHandoff,
  acknowledge: acknowledgeHandoff,
  close: closeHandoff,
  newId: randomUUID,
};

/** The caller's session id, with the refusals every one of the three shares. */
async function caller(sessionId: string | undefined, deps: HandoffDeps): Promise<string> {
  const me = await deps.origin(sessionId);
  if (!me) {
    throw new Error("Supply your session id; the caller could not be identified unambiguously.");
  }
  if (!deps.chainSlugOf(me)) {
    throw new Error("This session is not in a chain, so there is no handoff to write or answer.");
  }
  if (!deps.supported()) {
    throw new Error("This core does not record handoffs (no chainHandoffs capability).");
  }
  return me;
}

function mustWork(r: HandoffResult, what: string): void {
  if (!r.ok) throw new Error(`Could not ${what} (${r.error ?? "unknown"}).`);
}

const isSession = (o: Handoff["source"], id: string) => o.kind === "session" && o.sessionId === id;

/** Pass work to another session in the caller's chain. Throws, having written nothing,
 *  when the caller is not in a chain or the target is not in that same chain. */
export async function handOff(
  input: { sessionId?: string; to: string; summary: string; beadsIssue?: string },
  deps: HandoffDeps = defaultHandoffDeps,
): Promise<string> {
  const me = await caller(input.sessionId, deps);
  const chainSlug = deps.chainSlugOf(me)!;
  if (input.to === me) throw new Error("A session cannot hand off to itself.");
  if (deps.chainSlugOf(input.to) !== chainSlug) {
    throw new Error(`Session ${input.to} is not in your chain (${chainSlug}).`);
  }
  const id = deps.newId();
  mustWork(
    await deps.create({
      id,
      chainSlug,
      source: { kind: "session", sessionId: me },
      target: { kind: "session", sessionId: input.to },
      summary: input.summary,
      ...(input.beadsIssue ? { beadsIssue: input.beadsIssue } : {}),
    }),
    "record the handoff",
  );
  return `Handoff ${id} recorded in chain ${chainSlug}, pending until ${input.to} acknowledges it.`;
}

/** The handoff, if the caller is a party to it (`target` only, or either side). */
function owned(h: Handoff | null, me: string, parties: "target" | "either"): Handoff {
  if (!h) throw new Error("No such handoff.");
  if (!isSession(h.target, me) && !(parties === "either" && isSession(h.source, me))) {
    throw new Error(
      `Handoff ${h.id} is not ${parties === "target" ? "addressed to" : "yours:"} this session.`,
    );
  }
  return h;
}

/** Take responsibility for a handoff addressed to the caller. */
export async function ackHandoff(
  input: { sessionId?: string; handoffId: string },
  deps: HandoffDeps = defaultHandoffDeps,
): Promise<string> {
  const me = await caller(input.sessionId, deps);
  owned(deps.find(input.handoffId), me, "target");
  mustWork(await deps.acknowledge(input.handoffId), "acknowledge the handoff");
  return `Handoff ${input.handoffId} acknowledged.`;
}

/** Close a handoff the caller sent or received; `evidence` is the recorded reason. */
export async function closeChainHandoff(
  input: { sessionId?: string; handoffId: string; evidence: string },
  deps: HandoffDeps = defaultHandoffDeps,
): Promise<string> {
  const me = await caller(input.sessionId, deps);
  owned(deps.find(input.handoffId), me, "either");
  mustWork(await deps.close(input.handoffId, input.evidence), "close the handoff");
  return `Handoff ${input.handoffId} closed.`;
}
