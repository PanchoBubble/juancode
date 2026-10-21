// An in-memory stand-in for the daemon's chain book, for tests. It answers writes the
// way the core does (one chain per item, a refusal as an error code) so the callers
// in chains.ts and telegram.ts are exercised against the rules, not against stubs.

import type { ChainDeps } from "./chains.ts";
import type { Chain, ChainResult } from "./native-events.ts";
import type { LiveActivity, SessionSummary } from "./telegram-format.ts";

export interface FakeChainDeps extends ChainDeps {
  /** Every write sent, in order. */
  writes: Record<string, unknown>[];
}

export function fakeChainDeps({
  book = [] as Chain[],
  sessions = [] as SessionSummary[],
  activity = {} as Record<string, LiveActivity>,
  supported = true,
}: {
  book?: Chain[];
  sessions?: SessionSummary[];
  activity?: Record<string, LiveActivity>;
  supported?: boolean;
} = {}): FakeChainDeps {
  let chains = book.map((c) => ({ ...c, members: [...c.members] }));
  const writes: Record<string, unknown>[] = [];
  const answer = (op: string, slug: string | undefined, error?: string): ChainResult => {
    const result: ChainResult = { ok: !error, op };
    if (slug) result.slug = slug;
    if (error) result.error = error;
    return result;
  };
  return {
    writes,
    waitMs: 0,
    supported: () => supported,
    subscribe: () => supported,
    book: () => (supported ? chains : null),
    create: async (slug) => {
      writes.push({ type: "createChain", slug });
      if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(slug))
        return answer("create", slug, "chain-slug-invalid");
      if (chains.some((c) => c.slug === slug)) return answer("create", slug, "chain-exists");
      chains = [...chains, { slug, state: "active", createdAt: 1, closedAt: null, members: [] }];
      return answer("create", slug);
    },
    close: async (slug) => {
      writes.push({ type: "closeChain", slug });
      const chain = chains.find((c) => c.slug === slug);
      if (!chain) return answer("close", slug, "chain-not-found");
      chain.state = "inactive";
      chain.closedAt = 2;
      return answer("close", slug);
    },
    setMember: async (member) => {
      writes.push({ type: "setChainMember", ...member });
      const target = member.slug ? chains.find((c) => c.slug === member.slug) : undefined;
      if (member.slug && !target) return answer("setMember", member.slug, "chain-not-found");
      if (member.kind === "session" && !sessions.some((s) => s.id === member.ref)) {
        return answer("setMember", member.slug, "chain-member-not-found");
      }
      for (const c of chains) {
        c.members = c.members.filter((m) => !(m.kind === member.kind && m.ref === member.ref));
      }
      if (target) {
        const { kind, ref, title, url } = member;
        target.members.push({
          kind,
          ref,
          addedAt: 3,
          ...(title ? { title } : {}),
          ...(url ? { url } : {}),
        });
      }
      return answer("setMember", member.slug);
    },
    sessions: async () => sessions,
    activity: (id) => activity[id],
  };
}
