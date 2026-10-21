// Chains for the Oracle and the phone (juancode-dbo.10). The book is the daemon's,
// mirrored by native-events.ts over the shared :4280 socket; this module is the one
// place that reads it for a person or a model: list, show one chain with its members
// grouped by kind and the live status of its sessions, and the writes (create, tag,
// untag, close) answered in words. The MCP tools in index.ts and the Telegram /chains
// command both go through here, so the two surfaces cannot describe a chain
// differently.

import {
  chains,
  closeChain,
  createChain,
  onChains,
  sessionActivity,
  setChainMember,
  subscribeChains,
  supportsChains,
  type Chain,
  type ChainMember,
  type ChainMemberKind,
  type ChainResult,
} from "./native-events.ts";
import { listSessions } from "./oracle.ts";
import {
  parseSessionList,
  projectName,
  stateIcon,
  stateLabel,
  type LiveActivity,
  type SessionSummary,
} from "./telegram-format.ts";

export type ChainFilter = "active" | "inactive" | "all";

/** The collaborators, injected so every operation is testable without a socket. */
export interface ChainDeps {
  supported: () => boolean;
  /** Ask for the book; true once the subscription is out. */
  subscribe: () => boolean;
  book: () => Chain[] | null;
  create: (slug: string) => Promise<ChainResult>;
  close: (slug: string) => Promise<ChainResult>;
  setMember: (member: {
    kind: ChainMemberKind;
    ref: string;
    slug?: string;
    title?: string;
    url?: string;
  }) => Promise<ChainResult>;
  sessions: () => Promise<SessionSummary[]>;
  activity: (sessionId: string) => LiveActivity | undefined;
  /** How long to wait for the handshake and the first book. */
  waitMs?: number;
}

let watching = false;

/** Keep the book subscribed: a registered listener is what makes native-events
 *  subscribe on the handshake and again after every reconnect. Idempotent. */
export function watchChains(): void {
  if (watching) return;
  watching = true;
  onChains(() => {});
}

/** The real collaborators. */
export function defaultChainDeps(): ChainDeps {
  watchChains();
  return {
    supported: supportsChains,
    subscribe: subscribeChains,
    book: chains,
    create: createChain,
    close: closeChain,
    setMember: setChainMember,
    sessions: async () => parseSessionList(await listSessions()),
    activity: sessionActivity,
  };
}

export const KIND_LABELS: Record<ChainMemberKind, string> = {
  session: "Sessions",
  tracked_pr: "PRs",
  beads: "Beads issues",
  linear: "Linear tickets",
};

const KIND_ORDER: readonly ChainMemberKind[] = ["session", "tracked_pr", "beads", "linear"];

/** What a refusal means, in words a person can act on. */
const ERROR_TEXT: Record<string, string> = {
  "chain-exists": "a chain with that slug already exists",
  "chain-not-found": "no chain with that slug",
  "chain-member-not-found": "the core has no session with that id",
  "chain-member-invalid": "that is not a valid member",
  "chain-slug-empty": "the slug is empty",
  "chain-slug-invalid":
    "slugs are lowercase letters and digits in dash-separated words, e.g. auth-rewrite",
  "chain-slug-too-long": "slugs are at most 48 characters",
  "chain-store-failed": "the daemon could not save it",
  "chain-unavailable": "the daemon is not reachable or does not keep chains",
  "chain-timeout": "the daemon did not answer in time",
  "chain-connection-lost": "the connection to the daemon dropped before it answered",
};

export function chainErrorText(code: string | undefined): string {
  if (!code) return "the daemon refused it";
  return ERROR_TEXT[code] ?? code;
}

const nap = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** The book, subscribing first if nothing has yet. Waits a bounded moment for the
 *  handshake and the first `chains` frame, so a call right after boot still answers;
 *  throws rather than answering from no book at all. */
export async function readBook(deps: ChainDeps): Promise<Chain[]> {
  const deadline = Date.now() + (deps.waitMs ?? 3000);
  for (;;) {
    if (deps.supported()) {
      deps.subscribe();
      const book = deps.book();
      if (book) return book;
    }
    if (Date.now() >= deadline) break;
    await nap(25);
  }
  throw new Error(
    deps.supported()
      ? "The daemon has not sent its chains yet. Try again in a moment."
      : "Chains are unavailable: the juancode daemon is not reachable, or this core does not keep chains.",
  );
}

/** Group a chain's members by kind, kinds in a fixed order, members in join order. */
export function membersByKind(chain: Chain): [ChainMemberKind, ChainMember[]][] {
  return KIND_ORDER.map((kind): [ChainMemberKind, ChainMember[]] => [
    kind,
    chain.members.filter((m) => m.kind === kind),
  ]).filter(([, members]) => members.length > 0);
}

/** "2 sessions, 1 PR" — or "empty". */
export function memberSummary(chain: Chain): string {
  const parts = membersByKind(chain).map(([kind, members]) => {
    const n = members.length;
    switch (kind) {
      case "session":
        return `${n} session${n === 1 ? "" : "s"}`;
      case "tracked_pr":
        return `${n} PR${n === 1 ? "" : "s"}`;
      case "beads":
        return `${n} beads issue${n === 1 ? "" : "s"}`;
      case "linear":
        return `${n} Linear ticket${n === 1 ? "" : "s"}`;
    }
  });
  return parts.length > 0 ? parts.join(", ") : "empty";
}

export function filterChains(book: Chain[], filter: ChainFilter): Chain[] {
  return filter === "all" ? book : book.filter((c) => c.state === filter);
}

/** One line per chain, numbered from 1 so a phone can pick one by number. */
export function chainListText(book: Chain[], filter: ChainFilter): string {
  const list = filterChains(book, filter);
  if (list.length === 0) {
    return filter === "all" ? "No chains yet." : `No ${filter} chains.`;
  }
  return list
    .map((c, i) => {
      const closed = c.state === "inactive" ? " (closed)" : "";
      return `${i + 1}. ${c.slug}${closed} · ${memberSummary(c)}`;
    })
    .join("\n");
}

/** The tracked-PR key's number, for a readable line when no title was given. */
function prLabel(ref: string): string {
  const at = ref.lastIndexOf("#");
  if (at <= 0) return ref;
  return `${projectName(ref.slice(0, at))} #${ref.slice(at + 1)}`;
}

function memberLine(m: ChainMember, sessions: Map<string, SessionSummary>, deps: ChainDeps) {
  const url = m.url ? `\n    ${m.url}` : "";
  switch (m.kind) {
    case "session": {
      const s = sessions.get(m.ref);
      if (!s) return `- ${m.title ?? m.ref} · ${m.ref} · not in the session list${url}`;
      const activity = deps.activity(s.id);
      return (
        `- ${stateIcon(s.status, activity)} ${s.title} · ${projectName(s.cwd)} · ` +
        `${s.provider} · ${stateLabel(s.status, activity)} · ${s.id}${url}`
      );
    }
    case "tracked_pr":
      return `- ${m.title ? `${m.title} · ` : ""}${prLabel(m.ref)} · ${m.ref}${url}`;
    default:
      return `- ${m.ref}${m.title ? ` · ${m.title}` : ""}${url}`;
  }
}

/** One chain with every member, grouped by kind; sessions carry their live status.
 *  The session list is best-effort: a chain is still worth showing without it. */
export async function chainShowText(deps: ChainDeps, slug: string): Promise<string> {
  const chain = (await readBook(deps)).find((c) => c.slug === slug);
  if (!chain) throw new Error(`No chain named "${slug}".`);
  const sessions = new Map<string, SessionSummary>();
  if (chain.members.some((m) => m.kind === "session")) {
    for (const s of await deps.sessions().catch(() => [])) sessions.set(s.id, s);
  }
  const head =
    chain.state === "active"
      ? `${chain.slug} · active since ${isoDate(chain.createdAt)}`
      : `${chain.slug} · closed ${chain.closedAt ? isoDate(chain.closedAt) : ""}`.trimEnd();
  const groups = membersByKind(chain).map(
    ([kind, members]) =>
      `${KIND_LABELS[kind]} (${members.length}):\n` +
      members.map((m) => memberLine(m, sessions, deps)).join("\n"),
  );
  return [head, ...(groups.length > 0 ? groups : ["No members yet."])].join("\n\n");
}

function isoDate(ms: number): string {
  return ms > 0 ? new Date(ms).toISOString().slice(0, 10) : "?";
}

/** Throw a refusal as words; return quietly when the write happened. */
function expectOk(result: ChainResult, what: string): void {
  if (!result.ok) throw new Error(`Could not ${what}: ${chainErrorText(result.error)}.`);
}

export async function chainCreate(deps: ChainDeps, slug: string): Promise<string> {
  const result = await deps.create(slug);
  if (!result.ok && result.error === "chain-exists") {
    const existing = deps.book()?.find((c) => c.slug === slug);
    throw new Error(
      `Chain "${slug}" already exists${existing?.state === "inactive" ? " (closed)" : ""}. ` +
        "Use chain_add to tag work into it.",
    );
  }
  expectOk(result, `create "${slug}"`);
  return `Created chain "${slug}".`;
}

export async function chainClose(deps: ChainDeps, slug: string): Promise<string> {
  expectOk(await deps.close(slug), `close "${slug}"`);
  return `Closed chain "${slug}". Its members stay tagged; nothing was deleted.`;
}

const PR_KEY = /^\/.+#\d+$/;

/** Resolve what the caller named into the ref the core stores. A session may be
 *  named by a unique id prefix; a PR is its tracked key `<cwd>#<number>`, or the
 *  cwd and number given apart. Beads and Linear refs are taken as written. */
export async function resolveMemberRef(
  deps: ChainDeps,
  kind: ChainMemberKind,
  ref: string,
  prCwd?: string,
): Promise<string> {
  const raw = ref.trim();
  if (!raw) throw new Error("ref is empty.");
  if (kind === "session") {
    const sessions = await deps.sessions().catch(() => null);
    if (!sessions) return raw;
    if (sessions.some((s) => s.id === raw)) return raw;
    const prefixed = sessions.filter((s) => s.id.startsWith(raw));
    if (prefixed.length === 1) return prefixed[0]!.id;
    if (prefixed.length > 1) {
      throw new Error(`"${raw}" matches ${prefixed.length} sessions; give more of the id.`);
    }
    return raw;
  }
  if (kind === "tracked_pr") {
    const number = raw.replace(/^#/, "");
    const key = prCwd && /^\d+$/.test(number) ? `${prCwd.replace(/\/+$/, "")}#${number}` : raw;
    if (!PR_KEY.test(key)) {
      throw new Error(
        `A PR is named by its tracked key "<absolute repo path>#<number>", or by prCwd plus the number; got "${raw}".`,
      );
    }
    return key;
  }
  return raw;
}

export interface MemberInput {
  kind: ChainMemberKind;
  ref: string;
  /** For a PR named by number: the repo checkout it is tracked under. */
  prCwd?: string;
  title?: string;
  url?: string;
}

/** Tag an item into a chain, moving it out of any other. Says when it moved. */
export async function chainAdd(deps: ChainDeps, slug: string, input: MemberInput): Promise<string> {
  const ref = await resolveMemberRef(deps, input.kind, input.ref, input.prCwd);
  const book = await readBook(deps);
  const chain = book.find((c) => c.slug === slug);
  if (!chain) throw new Error(`No chain named "${slug}". Create it with chain_create first.`);
  const before = book.find((c) => c.members.some((m) => m.kind === input.kind && m.ref === ref));
  if (before?.slug === slug) return `${input.kind} ${ref} is already in "${slug}".`;
  const member: Parameters<ChainDeps["setMember"]>[0] = { kind: input.kind, ref, slug };
  if (input.title) member.title = input.title;
  if (input.url) member.url = input.url;
  expectOk(await deps.setMember(member), `add ${input.kind} ${ref} to "${slug}"`);
  const moved = before ? ` (moved out of "${before.slug}")` : "";
  const closed = chain.state === "inactive" ? ` Note: "${slug}" is closed.` : "";
  return `Added ${input.kind} ${ref} to "${slug}"${moved}.${closed}`;
}

/** Untag an item. With `slug`, refuses when the item is in a different chain, so a
 *  stale view cannot untag something somebody else has since moved. */
export async function chainRemove(
  deps: ChainDeps,
  input: Omit<MemberInput, "title" | "url"> & { slug?: string },
): Promise<string> {
  const ref = await resolveMemberRef(deps, input.kind, input.ref, input.prCwd);
  const book = await readBook(deps);
  const current = book.find((c) => c.members.some((m) => m.kind === input.kind && m.ref === ref));
  if (!current) return `${input.kind} ${ref} is not in any chain.`;
  if (input.slug && current.slug !== input.slug) {
    throw new Error(
      `${input.kind} ${ref} is in "${current.slug}", not "${input.slug}"; nothing was removed.`,
    );
  }
  expectOk(
    await deps.setMember({ kind: input.kind, ref }),
    `remove ${input.kind} ${ref} from "${current.slug}"`,
  );
  return `Removed ${input.kind} ${ref} from "${current.slug}".`;
}
