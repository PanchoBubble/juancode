import { afterEach, describe, expect, it, vi } from "vitest";
import { TrackedPrRegistry, type TrackChange, type TrackedPrDeps } from "./trackedPrs.ts";
import type { PrActivity } from "./gh.ts";
import type { PullRequest } from "./protocol.ts";

const pr = (over: Partial<PullRequest> = {}): PullRequest => ({
  number: 42,
  title: "Fix login",
  url: "https://github.com/o/r/pull/42",
  branch: "fix-login",
  draft: false,
  checks: "passing",
  author: "alice",
  ...over,
});

const activity = (over: Partial<PrActivity> = {}): PrActivity => ({
  checks: "none",
  comments: [],
  reviews: [],
  ...over,
});

/** A fake dep set with spies + a queueable `gh` activity script. */
function makeDeps(over: Partial<TrackedPrDeps> = {}) {
  const live = new Set<string>();
  let nextSessionId = 0;
  const seedSession = vi.fn();
  const injectPrompt = vi.fn();
  const reactivate = vi.fn(async () => {});
  const getPrActivity = vi.fn(async () => activity());
  const deps: TrackedPrDeps = {
    getPrActivity,
    spawnSession: vi.fn((_cwd: string) => {
      const id = `sess-${nextSessionId++}`;
      live.add(id);
      return id;
    }),
    sessionLive: (id) => live.has(id),
    seedSession,
    injectPrompt,
    reactivate,
    ...over,
  };
  return { deps, live, seedSession, injectPrompt, reactivate, getPrActivity };
}

describe("TrackedPrRegistry", () => {
  let reg: TrackedPrRegistry | null = null;
  afterEach(() => {
    reg?.dispose();
    reg = null;
  });

  it("track spawns a session, seeds it, and lists the PR; untrack drops it", () => {
    const { deps, seedSession } = makeDeps();
    reg = new TrackedPrRegistry(deps);

    reg.track(pr(), "/repo");
    const list = reg.list();
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({ id: "/repo#42", number: 42, sessionId: "sess-0", state: "watching" });
    expect(seedSession).toHaveBeenCalledOnce();
    expect(seedSession.mock.calls[0]?.[1]).toContain("#42");

    reg.untrack("/repo#42");
    expect(reg.list()).toEqual([]);
  });

  it("is a no-op when tracking an already-tracked PR", () => {
    const { deps } = makeDeps();
    reg = new TrackedPrRegistry(deps);
    reg.track(pr(), "/repo");
    reg.track(pr(), "/repo");
    expect(reg.list()).toHaveLength(1);
    expect(deps.spawnSession).toHaveBeenCalledOnce();
  });

  it("does not track when the session can't be spawned", () => {
    const { deps } = makeDeps({ spawnSession: () => null });
    reg = new TrackedPrRegistry(deps);
    reg.track(pr(), "/repo");
    expect(reg.list()).toEqual([]);
  });

  it("first poll only baselines (no fix prompt) and stamps lastPolledAt", async () => {
    const { deps, injectPrompt } = makeDeps({
      getPrActivity: vi.fn(async () =>
        activity({ comments: [{ id: "c1", author: "bob", body: "fix" }] }),
      ),
    });
    reg = new TrackedPrRegistry(deps);
    reg.track(pr(), "/repo");
    await reg.pollOnce();
    expect(injectPrompt).not.toHaveBeenCalled();
    expect(reg.list()[0]?.lastPolledAt).toBeTypeOf("number");
  });

  it("injects an auto-fix prompt when new activity appears after the baseline", async () => {
    let comments: { id: string; author: string; body: string }[] = [];
    const { deps, injectPrompt } = makeDeps({
      getPrActivity: vi.fn(async () => activity({ comments })),
    });
    reg = new TrackedPrRegistry(deps);
    reg.track(pr(), "/repo");
    await reg.pollOnce(); // baseline (empty)
    comments = [{ id: "c1", author: "bob", body: "please fix" }];
    await reg.pollOnce(); // new comment → auto-fix
    expect(injectPrompt).toHaveBeenCalledOnce();
    expect(injectPrompt.mock.calls[0]?.[1]).toContain("1 new comment from @bob");
  });

  it("raises a needs-decision notification + state and broadcasts a ping", async () => {
    let reviews: { id: string; author: string; body: string; state: string }[] = [];
    const { deps } = makeDeps({ getPrActivity: vi.fn(async () => activity({ reviews })) });
    reg = new TrackedPrRegistry(deps);
    const changes: TrackChange[] = [];
    reg.onChange((c) => changes.push(c));

    reg.track(pr(), "/repo");
    await reg.pollOnce(); // baseline
    reviews = [{ id: "r1", author: "bob", body: "no", state: "CHANGES_REQUESTED" }];
    await reg.pollOnce();

    const info = reg.list()[0]!;
    expect(info.state).toBe("needs_decision");
    expect(info.notifications).toHaveLength(1);
    expect(info.notifications[0]?.message).toBe("@bob requested changes");
    expect(changes.some((c) => c.kind === "notification")).toBe(true);

    // Resolving the notification clears the badge.
    reg.resolveNotification("/repo#42", info.notifications[0]!.id);
    expect(reg.list()[0]?.state).toBe("watching");
  });

  it("revives an offline driving session before injecting the fix", async () => {
    let comments: { id: string; author: string; body: string }[] = [];
    const { deps, injectPrompt, reactivate, live } = makeDeps({
      getPrActivity: vi.fn(async () => activity({ comments })),
    });
    reg = new TrackedPrRegistry(deps);
    reg.track(pr(), "/repo");
    await reg.pollOnce(); // baseline
    live.delete("sess-0"); // session exited
    reactivate.mockImplementation(async () => {
      live.add("sess-0"); // revival succeeds
    });
    comments = [{ id: "c1", author: "bob", body: "fix" }];
    await reg.pollOnce();
    expect(reactivate).toHaveBeenCalledWith("sess-0");
    expect(injectPrompt).toHaveBeenCalledOnce();
  });

  it("escalates when the driving session is offline and can't be revived", async () => {
    let comments: { id: string; author: string; body: string }[] = [];
    const { deps, injectPrompt, live } = makeDeps({
      getPrActivity: vi.fn(async () => activity({ comments })),
    });
    reg = new TrackedPrRegistry(deps);
    reg.track(pr(), "/repo");
    await reg.pollOnce(); // baseline
    live.delete("sess-0"); // exited, and reactivate (default no-op) won't revive it
    comments = [{ id: "c1", author: "bob", body: "fix" }];
    await reg.pollOnce();
    expect(injectPrompt).not.toHaveBeenCalled();
    const notes = reg.list()[0]!.notifications;
    expect(notes.some((n) => n.message.includes("offline"))).toBe(true);
  });

  it("skips a PR whose poll returns null (couldn't reach gh)", async () => {
    const { deps, injectPrompt } = makeDeps({ getPrActivity: vi.fn(async () => null) });
    reg = new TrackedPrRegistry(deps);
    reg.track(pr(), "/repo");
    await reg.pollOnce();
    expect(injectPrompt).not.toHaveBeenCalled();
    expect(reg.list()[0]?.lastPolledAt).toBeNull();
  });
});
