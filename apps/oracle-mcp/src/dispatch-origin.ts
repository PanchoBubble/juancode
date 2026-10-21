// Which session a dispatch came from, so the daemon can put the new session in that
// session's chain, starting one when it has none (`create.fromSessionId`, capability
// `chainInherit`).
//
// The MCP server is one stateless HTTP endpoint every Oracle shares, so a tool call
// does not say who made it, and an Oracle does not know its own juancode session id.
// The answer is worked out here instead, in this order:
//
//   1. The id the caller gave: a CLI session id first (a Claude Code session dispatching
//      through the skill passes its own `$CLAUDE_CODE_SESSION_ID`), else resolved like
//      any session ref (exact, or a unique prefix). An id this list lacks goes through
//      as written: the daemon leaves the new session untagged for a source it does not
//      know.
//   2. Otherwise the one Oracle session — running, unarchived, in the control dir —
//      that is mid-turn. An Oracle making a tool call is busy; an idle one is not
//      making it. Busy is required even of a lone Oracle, because the headless phone
//      chat also runs in the control dir and dispatches, without being a session at
//      all: while it does, the desktop Oracle sitting idle is not the caller.
//   3. Otherwise none. The dispatch goes ahead unchained, which is also what a core
//      without `chainInherit` does with the field.

import { resolve } from "node:path";
import { sessionActivity } from "./native-events.ts";
import { listSessions, oracleDir } from "./oracle.ts";
import {
  parseSessionList,
  resolveSessionRef,
  type LiveActivity,
  type SessionSummary,
} from "./telegram-format.ts";

export interface OriginDeps {
  sessions?: () => Promise<SessionSummary[]>;
  activity?: (sessionId: string) => LiveActivity | undefined;
  controlDir?: () => string;
}

const samePath = (a: string, b: string) => a !== "" && resolve(a) === resolve(b);

/** The session this dispatch came from, or null when it cannot be told. Throws only
 *  for a given ref that matches several sessions, before anything is created. */
export async function resolveDispatchOrigin(
  given: string | null | undefined,
  deps: OriginDeps = {},
): Promise<string | null> {
  const raw = given?.trim() ?? "";
  const fetch = deps.sessions ?? (async () => parseSessionList(await listSessions()));
  const sessions = await fetch().catch((): SessionSummary[] | null => null);
  if (raw) {
    if (!sessions) return raw;
    const byCli = sessions.find((s) => s.cliSessionId === raw);
    return byCli ? byCli.id : resolveSessionRef(sessions, raw);
  }
  if (!sessions) return null;

  const dir = (deps.controlDir ?? oracleDir)();
  const oracles = sessions.filter(
    (s) => s.status === "running" && !s.archived && samePath(s.cwd, dir),
  );
  const activity = deps.activity ?? sessionActivity;
  const busy = oracles.filter((s) => activity(s.id) === "busy");
  return busy.length === 1 ? busy[0]!.id : null;
}
