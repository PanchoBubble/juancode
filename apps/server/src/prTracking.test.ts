import { describe, expect, it } from "vitest";
import {
  autoFixPrompt,
  classifyPrActivity,
  deriveTrackState,
  emptySnapshot,
  orderedUniqueAuthors,
  trackSeedPrompt,
} from "./prTracking.ts";
import type { PrActivity } from "./gh.ts";

const activity = (over: Partial<PrActivity> = {}): PrActivity => ({
  state: "OPEN",
  checks: "none",
  comments: [],
  reviews: [],
  ...over,
});

describe("classifyPrActivity", () => {
  it("emits no events on the first (un-baselined) poll, only records the baseline", () => {
    const result = classifyPrActivity(
      emptySnapshot(),
      activity({
        checks: "failing",
        comments: [{ id: "c1", author: "alice", body: "hi" }],
        reviews: [{ id: "r1", author: "bob", body: "", state: "CHANGES_REQUESTED" }],
      }),
    );
    expect(result.events).toEqual([]);
    expect(result.snapshot.baselined).toBe(true);
    expect(result.snapshot.checks).toBe("failing");
    expect(result.snapshot.seenCommentIds).toEqual(new Set(["c1"]));
    expect(result.snapshot.seenReviewIds).toEqual(new Set(["r1"]));
  });

  it("auto-fixes new comments and summarises distinct authors", () => {
    const prev = { ...emptySnapshot(), baselined: true };
    const result = classifyPrActivity(
      prev,
      activity({
        comments: [
          { id: "c1", author: "alice", body: "fix this" },
          { id: "c2", author: "alice", body: "and that" },
          { id: "c3", author: "bob", body: "also" },
        ],
      }),
    );
    expect(result.events).toEqual([{ kind: "autoFix", reason: "3 new comments from @alice, @bob" }]);
  });

  it("ignores comments already seen", () => {
    const prev = { ...emptySnapshot(), baselined: true, seenCommentIds: new Set(["c1"]) };
    const result = classifyPrActivity(
      prev,
      activity({ comments: [{ id: "c1", author: "alice", body: "old" }] }),
    );
    expect(result.events).toEqual([]);
  });

  it("escalates a CHANGES_REQUESTED review to needs-decision", () => {
    const prev = { ...emptySnapshot(), baselined: true };
    const result = classifyPrActivity(
      prev,
      activity({ reviews: [{ id: "r1", author: "bob", body: "no", state: "CHANGES_REQUESTED" }] }),
    );
    expect(result.events).toEqual([{ kind: "needsDecision", reason: "@bob requested changes" }]);
  });

  it("auto-fixes a non-empty COMMENTED review but ignores an empty one", () => {
    const prev = { ...emptySnapshot(), baselined: true };
    const withBody = classifyPrActivity(
      prev,
      activity({ reviews: [{ id: "r1", author: "bob", body: "thoughts", state: "COMMENTED" }] }),
    );
    expect(withBody.events).toEqual([{ kind: "autoFix", reason: "New review from @bob" }]);

    const empty = classifyPrActivity(
      prev,
      activity({ reviews: [{ id: "r2", author: "bob", body: "   ", state: "COMMENTED" }] }),
    );
    expect(empty.events).toEqual([]);
  });

  it("ignores APPROVED / DISMISSED reviews", () => {
    const prev = { ...emptySnapshot(), baselined: true };
    const result = classifyPrActivity(
      prev,
      activity({
        reviews: [
          { id: "r1", author: "a", body: "lgtm", state: "APPROVED" },
          { id: "r2", author: "b", body: "", state: "DISMISSED" },
        ],
      }),
    );
    expect(result.events).toEqual([]);
  });

  it("auto-fixes only on the transition into failing CI", () => {
    const wentRed = classifyPrActivity(
      { ...emptySnapshot(), baselined: true, checks: "passing" },
      activity({ checks: "failing" }),
    );
    expect(wentRed.events).toEqual([{ kind: "autoFix", reason: "CI checks are failing" }]);

    const stayedRed = classifyPrActivity(
      { ...emptySnapshot(), baselined: true, checks: "failing" },
      activity({ checks: "failing" }),
    );
    expect(stayedRed.events).toEqual([]);
  });

  it("names an anonymous reviewer when the login is empty", () => {
    const prev = { ...emptySnapshot(), baselined: true };
    const result = classifyPrActivity(
      prev,
      activity({ reviews: [{ id: "r1", author: "", body: "", state: "CHANGES_REQUESTED" }] }),
    );
    expect(result.events).toEqual([{ kind: "needsDecision", reason: "a reviewer requested changes" }]);
  });

  it("emits a single closed event when the PR merges or closes, ignoring other activity", () => {
    const prev = { ...emptySnapshot(), baselined: true };
    const merged = classifyPrActivity(
      prev,
      activity({ state: "MERGED", checks: "failing", comments: [{ id: "c1", author: "a", body: "hi" }] }),
    );
    expect(merged.events).toEqual([{ kind: "closed", reason: "PR was merged — stopped tracking" }]);

    const closed = classifyPrActivity(prev, activity({ state: "CLOSED" }));
    expect(closed.events).toEqual([{ kind: "closed", reason: "PR was closed — stopped tracking" }]);
  });

  it("emits closed even before the first baseline (already-merged PR)", () => {
    const result = classifyPrActivity(emptySnapshot(), activity({ state: "MERGED" }));
    expect(result.events).toEqual([{ kind: "closed", reason: "PR was merged — stopped tracking" }]);
  });
});

describe("orderedUniqueAuthors", () => {
  it("dedups and drops empties in first-seen order", () => {
    expect(orderedUniqueAuthors(["alice", "", "bob", "alice"])).toBe("@alice, @bob");
    expect(orderedUniqueAuthors(["", ""])).toBe("");
  });
});

describe("deriveTrackState", () => {
  it("prioritises an open decision over CI", () => {
    expect(deriveTrackState("passing", true)).toBe("needs_decision");
    expect(deriveTrackState("failing", true)).toBe("needs_decision");
  });

  it("maps CI status to fixing / watching when nothing is outstanding", () => {
    expect(deriveTrackState("failing", false)).toBe("fixing");
    expect(deriveTrackState("pending", false)).toBe("fixing");
    expect(deriveTrackState("passing", false)).toBe("watching");
    expect(deriveTrackState("none", false)).toBe("watching");
  });
});

describe("prompt builders", () => {
  it("seed prompt carries the PR identity and the fix-or-escalate contract", () => {
    const p = trackSeedPrompt({ number: 42, title: "Fix login", branch: "fix-login", url: "https://x/42" });
    expect(p).toContain("#42");
    expect(p).toContain("Fix login");
    expect(p).toContain("`fix-login`");
    expect(p).toContain("https://x/42");
    expect(p).toContain("STOP");
  });

  it("auto-fix prompt summarises the reasons and restates the contract", () => {
    const p = autoFixPrompt({ number: 7, branch: "feat", reasons: ["CI checks are failing", "2 new comments"] });
    expect(p).toContain("#7");
    expect(p).toContain("CI checks are failing; 2 new comments");
    expect(p).toContain("`feat`");
    expect(p).toContain("STOP");
  });

  it("auto-fix prompt falls back to a generic summary with no reasons", () => {
    expect(autoFixPrompt({ number: 1, branch: "b", reasons: [] })).toContain("new activity");
  });
});
