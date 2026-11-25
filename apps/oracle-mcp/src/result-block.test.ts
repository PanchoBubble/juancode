import { describe, expect, it } from "vitest";
import { extractResultBlock } from "./result-block.ts";

describe("extractResultBlock", () => {
  it("returns only the last RESULT block, capped", () => {
    const text =
      "long work log\nRESULT\nstatus: blocked\n\nmore\nRESULT\nstatus: done\nchanged: a.ts\nverified: tests";
    expect(extractResultBlock(text)).toBe("RESULT\nstatus: done\nchanged: a.ts\nverified: tests");
    const long = `RESULT\nstatus: done\n${Array.from({ length: 40 }, (_, i) => `l${i}`).join("\n")}`;
    expect(extractResultBlock(long)!.split("\n")).toHaveLength(15);
  });

  it("is null without a RESULT line followed by a status", () => {
    expect(extractResultBlock("the RESULT was good")).toBeNull();
    expect(extractResultBlock("RESULT\nno status here")).toBeNull();
  });
});
