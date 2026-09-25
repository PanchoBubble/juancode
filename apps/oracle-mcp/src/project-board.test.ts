import { describe, expect, it } from "vitest";

import { isLiveSession, toIssueDetail, toIssues } from "./oracle.ts";

describe("toIssues", () => {
  it("keeps each dependency edge and takes the parent from a parent-child edge", () => {
    const [issue] = toIssues(
      [
        {
          id: "p-1.2",
          title: "child",
          status: "open",
          priority: 1,
          issue_type: "bug",
          updated_at: "2026-09-25T10:00:00Z",
          dependencies: [
            { issue_id: "p-1.2", depends_on_id: "p-1", type: "parent-child" },
            { issue_id: "p-1.2", depends_on_id: "p-9", type: "blocks" },
          ],
        },
      ],
      new Set(["p-1.2"]),
    );
    expect(issue).toEqual({
      id: "p-1.2",
      title: "child",
      status: "open",
      priority: 1,
      issueType: "bug",
      parent: "p-1",
      ready: true,
      deps: [
        { id: "p-1", type: "parent-child" },
        { id: "p-9", type: "blocks" },
      ],
      updatedAt: "2026-09-25T10:00:00Z",
      closedAt: null,
    });
  });

  it("drops rows without an id and tolerates a non-array", () => {
    expect(toIssues([{ title: "no id" }], new Set())).toEqual([]);
    expect(toIssues(null, new Set())).toEqual([]);
  });
});

describe("toIssueDetail", () => {
  it("reads bd show's dependency and comment shapes", () => {
    const d = toIssueDetail({
      id: "p-2",
      title: "t",
      description: "body",
      status: "closed",
      close_reason: "Done",
      dependencies: [{ id: "p-1", title: "dep", status: "open", dependency_type: "blocks" }],
      comments: [{ author: "me", text: "hi", created_at: "2026-09-25T10:00:00Z" }],
    });
    expect(d.deps).toEqual([{ id: "p-1", title: "dep", status: "open", type: "blocks" }]);
    expect(d.comments).toEqual([{ author: "me", text: "hi", createdAt: "2026-09-25T10:00:00Z" }]);
    expect(d.closeReason).toBe("Done");
  });

  it("refuses a row with no id", () => {
    expect(() => toIssueDetail(undefined)).toThrow("issue not found");
  });
});

describe("isLiveSession", () => {
  it("is live only while the core has not marked it exited, and never when archived", () => {
    expect(isLiveSession({ status: "running" })).toBe(true);
    expect(isLiveSession({ status: "exited" })).toBe(false);
    expect(isLiveSession({ status: "running", archived: true })).toBe(false);
    expect(isLiveSession({})).toBe(false);
  });
});
