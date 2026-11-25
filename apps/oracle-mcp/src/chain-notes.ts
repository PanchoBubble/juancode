// Chain notes (juancode-cmew follow-up): a running log per chain, so what you ask
// for while a swarm works is not lost and the agents can keep a summary you can read.
// Each chain gets an append-only JSONL file the native app reads directly and also
// appends your own notes to. Agents post and read through the HTTP API or the
// chain_note / chain_notes MCP tools.
//
// shortcut: notes live in a sidecar-owned file, not in the daemon's chain book, so
// only clients on this machine see them; move them into the daemon (beside
// handoffs) if a remote client needs them.

import { appendFile, mkdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Chain } from "./native-events.ts";
import { readBook, type ChainDeps } from "./chains.ts";
import { resolveDispatchOrigin } from "./dispatch-origin.ts";

export type ChainNoteKind = "note" | "summary";

export interface ChainNote {
  at: number;
  /** "you" for the human, else the juancode session id that wrote it. */
  author: string;
  /** The writer's session title, when known. */
  authorName?: string;
  kind: ChainNoteKind;
  text: string;
}

export const MAX_NOTE_CHARS = 8000;
const SAFE_ID = /^[A-Za-z0-9._-]+$/;

export function chainNotesDir(): string {
  return process.env.JUANCODE_CHAIN_NOTES_DIR || join(homedir(), ".juancode", "chain-notes");
}

/** The chain's file. The id comes from the daemon's book, but it still names a
 *  path, so anything that could climb out of the directory is refused. */
export function chainNotesPath(chainId: string, dir = chainNotesDir()): string {
  if (!SAFE_ID.test(chainId) || chainId.startsWith(".")) {
    throw new Error(`Unusable chain id "${chainId}".`);
  }
  return join(dir, `${chainId}.jsonl`);
}

export const chainKey = (c: Chain): string => c.id ?? c.slug;

export interface NoteTarget {
  /** A chain's id, slug or name. */
  chain?: string;
  /** Or a session in it: a juancode id, unique prefix, or the CLI's own session id. */
  fromSessionId?: string;
}

/** Which chain a note is for, and the writing session when one was named. */
export async function resolveNoteChain(
  deps: ChainDeps,
  target: NoteTarget,
  origin: typeof resolveDispatchOrigin = resolveDispatchOrigin,
): Promise<{ chain: Chain; sessionId: string | null }> {
  const book = await readBook(deps);
  const named = target.chain?.trim();
  const from = target.fromSessionId?.trim();
  // An empty fromSessionId must not fall back to "the busy Oracle" guess.
  const sessionId = from ? await origin(from, { sessions: deps.sessions }) : null;
  if (named) {
    const lower = named.toLowerCase();
    const chain =
      book.find((c) => c.id === named || c.slug === named) ??
      book.find((c) => (c.name ?? "").toLowerCase() === lower);
    if (!chain) throw new Error(`No chain "${named}".`);
    return { chain, sessionId };
  }
  if (!sessionId) throw new Error("Name the chain, or the session writing (fromSessionId).");
  const chain = book.find((c) =>
    c.members.some((m) => m.kind === "session" && m.ref === sessionId),
  );
  if (!chain) throw new Error(`Session ${sessionId.slice(0, 8)} is not in a chain.`);
  return { chain, sessionId };
}

export async function appendChainNote(
  chainId: string,
  note: Omit<ChainNote, "at"> & { at?: number },
  dir = chainNotesDir(),
): Promise<ChainNote> {
  const text = note.text.trim();
  if (!text) throw new Error("The note is empty.");
  if (text.length > MAX_NOTE_CHARS)
    throw new Error(`Notes are at most ${MAX_NOTE_CHARS} characters.`);
  const full: ChainNote = { ...note, text, at: note.at ?? Date.now() };
  await mkdir(dir, { recursive: true });
  // One write of one line with O_APPEND, so the app's own appends cannot interleave.
  await appendFile(chainNotesPath(chainId, dir), JSON.stringify(full) + "\n", "utf8");
  return full;
}

/** Oldest first. A torn or foreign line is skipped, never fatal. */
export async function readChainNotes(chainId: string, dir = chainNotesDir()): Promise<ChainNote[]> {
  let raw: string;
  try {
    raw = await readFile(chainNotesPath(chainId, dir), "utf8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw err;
  }
  const out: ChainNote[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      const n = JSON.parse(line) as ChainNote;
      if (typeof n.text === "string" && typeof n.at === "number") out.push(n);
    } catch {
      // skip
    }
  }
  return out;
}

/** The latest summary and the last `limit` plain notes: what both bodies of GET show. */
function pickNotes(notes: ChainNote[], limit: number) {
  return {
    summary: [...notes].reverse().find((n) => n.kind === "summary") ?? null,
    tail: notes.filter((n) => n.kind === "note").slice(-limit),
  };
}

/** The notes as an agent reads them: the latest summary, then the last `limit` notes. */
export function chainNotesText(chain: Chain, notes: ChainNote[], limit = 40): string {
  const name = chain.name ?? chain.slug;
  if (notes.length === 0) return `No notes on "${name}" yet.`;
  const who = (n: ChainNote) =>
    n.author === "you" ? "you" : (n.authorName ?? n.author.slice(0, 8));
  const stamp = (n: ChainNote) => new Date(n.at).toISOString().slice(0, 16).replace("T", " ");
  const { summary, tail } = pickNotes(notes, limit);
  const parts = [`Notes on "${name}"`];
  if (summary) parts.push(`Summary (${who(summary)}, ${stamp(summary)}):\n${summary.text}`);
  if (tail.length > 0)
    parts.push(tail.map((n) => `- [${stamp(n)} ${who(n)}] ${n.text}`).join("\n"));
  return parts.join("\n\n");
}

/** Post a note: resolve the chain, stamp the writer, append. */
export async function postChainNote(
  deps: ChainDeps,
  input: NoteTarget & { text: string; kind?: ChainNoteKind; asHuman?: boolean },
  dir = chainNotesDir(),
): Promise<{ chain: Chain; note: ChainNote }> {
  const { chain, sessionId } = await resolveNoteChain(deps, input);
  const kind: ChainNoteKind = input.kind === "summary" ? "summary" : "note";
  let author = "you";
  let authorName: string | undefined;
  if (sessionId && !input.asHuman) {
    author = sessionId;
    const s = (await deps.sessions().catch(() => [])).find((x) => x.id === sessionId);
    if (s?.title) authorName = s.title;
  }
  const note = await appendChainNote(
    chainKey(chain),
    { author, kind, text: input.text, ...(authorName ? { authorName } : {}) },
    dir,
  );
  return { chain, note };
}

/** Read a chain's notes as text, for agents. */
export async function chainNotesFor(
  deps: ChainDeps,
  target: NoteTarget,
  limit?: number,
  dir = chainNotesDir(),
): Promise<string> {
  const { chain } = await resolveNoteChain(deps, target);
  return chainNotesText(chain, await readChainNotes(chainKey(chain), dir), limit);
}

/** The same notes as JSON, for scripts: {chain, name, summary, notes[]}. */
export async function chainNotesJson(
  deps: ChainDeps,
  target: NoteTarget,
  limit = 40,
  dir = chainNotesDir(),
) {
  const { chain } = await resolveNoteChain(deps, target);
  const { summary, tail } = pickNotes(await readChainNotes(chainKey(chain), dir), limit);
  return { chain: chainKey(chain), name: chain.name ?? chain.slug, summary, notes: tail };
}
