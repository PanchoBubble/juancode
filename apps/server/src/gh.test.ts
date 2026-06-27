import { describe, expect, it } from "vitest";
import { parsePrActivity, parsePrs, rollupChecks } from "./gh.ts";

describe("rollupChecks", () => {
  it("returns none for empty or missing checks", () => {
    expect(rollupChecks(null)).toBe("none");
    expect(rollupChecks([])).toBe("none");
  });

  it("returns failing when any CheckRun concluded in failure", () => {
    expect(
      rollupChecks([
        { status: "COMPLETED", conclusion: "SUCCESS" },
        { status: "COMPLETED", conclusion: "FAILURE" },
      ]),
    ).toBe("failing");
  });

  it("returns failing for a failed legacy status context", () => {
    expect(rollupChecks([{ state: "FAILURE" }])).toBe("failing");
  });

  it("returns pending when a run is still in progress and none failed", () => {
    expect(
      rollupChecks([
        { status: "COMPLETED", conclusion: "SUCCESS" },
        { status: "IN_PROGRESS" },
      ]),
    ).toBe("pending");
  });

  it("returns pending for a pending status context", () => {
    expect(rollupChecks([{ state: "PENDING" }])).toBe("pending");
  });

  it("returns passing when everything concluded successfully", () => {
    expect(
      rollupChecks([
        { status: "COMPLETED", conclusion: "SUCCESS" },
        { state: "SUCCESS" },
      ]),
    ).toBe("passing");
  });

  it("prioritises failing over pending", () => {
    expect(
      rollupChecks([{ status: "IN_PROGRESS" }, { status: "COMPLETED", conclusion: "ERROR" }]),
    ).toBe("failing");
  });
});

describe("parsePrs", () => {
  it("maps gh fields onto the wire shape and rolls up checks", () => {
    const out = parsePrs([
      {
        number: 42,
        title: "Fix login",
        url: "https://github.com/o/r/pull/42",
        headRefName: "fix-login",
        isDraft: false,
        statusCheckRollup: [{ status: "COMPLETED", conclusion: "SUCCESS" }],
        author: { login: "octocat" },
      },
      {
        number: 7,
        title: "WIP toggle",
        url: "https://github.com/o/r/pull/7",
        headRefName: "toggle",
        isDraft: true,
        statusCheckRollup: null,
      },
    ]);
    expect(out).toEqual([
      {
        number: 42,
        title: "Fix login",
        url: "https://github.com/o/r/pull/42",
        branch: "fix-login",
        draft: false,
        checks: "passing",
        author: "octocat",
      },
      {
        number: 7,
        title: "WIP toggle",
        url: "https://github.com/o/r/pull/7",
        branch: "toggle",
        draft: true,
        checks: "none",
        author: "",
      },
    ]);
  });
});

describe("parsePrActivity", () => {
  it("maps comments/reviews, rolls up checks, and upper-cases review state", () => {
    const out = parsePrActivity({
      statusCheckRollup: [{ status: "COMPLETED", conclusion: "FAILURE" }],
      comments: [{ id: "c1", author: { login: "alice" }, body: "fix" }],
      reviews: [{ id: "r1", author: { login: "bob" }, body: "no", state: "changes_requested" }],
    });
    expect(out).toEqual({
      checks: "failing",
      comments: [{ id: "c1", author: "alice", body: "fix" }],
      reviews: [{ id: "r1", author: "bob", body: "no", state: "CHANGES_REQUESTED" }],
    });
  });

  it("drops comments/reviews missing an id and defaults missing fields", () => {
    const out = parsePrActivity({
      comments: [{ author: { login: "alice" } }, { id: "c2" }],
      reviews: [{ state: "APPROVED" }, { id: "r2" }],
    });
    expect(out).toEqual({
      checks: "none",
      comments: [{ id: "c2", author: "", body: "" }],
      reviews: [{ id: "r2", author: "", body: "", state: "" }],
    });
  });
});
