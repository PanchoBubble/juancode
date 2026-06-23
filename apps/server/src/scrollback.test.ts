import { describe, expect, it } from "vitest";
import { appendScrollback } from "./scrollback.ts";

describe("appendScrollback", () => {
  it("appends when under the limit", () => {
    expect(appendScrollback("ab", "cd", 100)).toBe("abcd");
  });

  it("trims oldest characters past the limit", () => {
    expect(appendScrollback("abcd", "ef", 4)).toBe("cdef");
  });

  it("handles a chunk larger than the limit", () => {
    expect(appendScrollback("", "abcdef", 3)).toBe("def");
  });

  it("keeps exactly the limit when equal", () => {
    expect(appendScrollback("ab", "cd", 4)).toBe("abcd");
  });
});
