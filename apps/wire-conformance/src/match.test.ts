import { describe, expect, it } from "vitest";

import { matchValue, readBindings, resolveVars } from "./match.ts";

describe("matchValue", () => {
  it("matches objects partially and arrays exactly", () => {
    const frame = { type: "created", session: { id: "s1", cwd: "/tmp", extra: 1 } };
    expect(matchValue(frame, { type: "created", session: { id: "s1" } }).ok).toBe(true);
    expect(matchValue({ items: [1, 2] }, { items: [1, 2] }).ok).toBe(true);
    expect(matchValue({ items: [1, 2] }, { items: [1] }).ok).toBe(false);
  });

  it("reports the path of the first mismatch", () => {
    const result = matchValue({ session: { id: "a" } }, { session: { id: "b" } });
    expect(result.ok).toBe(false);
    expect(result.why).toContain("session.id");
  });

  it("distinguishes an absent key from a null value", () => {
    expect(matchValue({ exitCode: null }, { exitCode: { $absent: true } }).ok).toBe(false);
    expect(matchValue({}, { exitCode: { $absent: true } }).ok).toBe(true);
    expect(matchValue({ exitCode: null }, { exitCode: null }).ok).toBe(true);
  });

  it("supports the numeric, string and array operators", () => {
    expect(matchValue({ files: 3 }, { files: { $gte: 1 } }).ok).toBe(true);
    expect(matchValue({ files: 0 }, { files: { $gte: 1 } }).ok).toBe(false);
    expect(matchValue({ data: "hello world" }, { data: { $contains: "world" } }).ok).toBe(true);
    expect(matchValue({ lines: [1, 2, 3] }, { lines: { $length: 3 } }).ok).toBe(true);
    expect(matchValue({ caps: ["a", "b"] }, { caps: { $contains: "b" } }).ok).toBe(true);
    expect(
      matchValue({ lines: [{ row: 0 }, { row: 4 }] }, { lines: { $some: { row: 4 } } }).ok,
    ).toBe(true);
    expect(matchValue({ state: "idle" }, { state: { $oneOf: ["busy", "idle"] } }).ok).toBe(true);
  });

  it("compares a numeric operator against a bound variable", () => {
    // A transcript's live batch is asserted to be strictly above the last seq its
    // replay carried, and that number only exists as a binding.
    const vars = { baseSeq: 3 };
    expect(matchValue({ seq: 4 }, { seq: { $gt: "$baseSeq" } }, vars).ok).toBe(true);
    expect(matchValue({ seq: 3 }, { seq: { $gt: "$baseSeq" } }, vars).ok).toBe(false);
    // An unbound name is a failure, not a silent NaN comparison that always fails
    // for the wrong reason.
    expect(matchValue({ seq: 4 }, { seq: { $gt: "$missing" } }).why).toContain("needs a number");
  });

  it("resolves bound variables on both sides", () => {
    const vars = { session: "s-42" };
    expect(matchValue({ sessionId: "s-42" }, { sessionId: "$session" }, vars).ok).toBe(true);
    expect(matchValue({ sessionId: "other" }, { sessionId: "$session" }, vars).ok).toBe(false);
    expect(resolveVars({ sessionId: "$session", n: 1 }, vars)).toEqual({ sessionId: "s-42", n: 1 });
  });

  it("rejects an unknown operator instead of silently passing", () => {
    const result = matchValue({ a: 1 }, { a: { $nope: 1 } });
    expect(result.ok).toBe(false);
    expect(result.why).toContain("$nope");
  });
});

describe("readBindings", () => {
  it("reads through objects and array indices", () => {
    const frame = { session: { id: "s1" }, items: [{ id: "m1" }, { id: "m2" }] };
    expect(readBindings(frame, { session: "session.id", second: "items.1.id" })).toEqual({
      session: "s1",
      second: "m2",
    });
  });
});
