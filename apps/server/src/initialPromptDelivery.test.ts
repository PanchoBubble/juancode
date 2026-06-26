import { describe, expect, it } from "vitest";
import { promptSignature, regionContains } from "./initialPromptDelivery.ts";

/** Mirrors apps/native/Tests/JuancodeCoreTests/InitialPromptDeliveryTests.swift. */
describe("initialPromptDelivery", () => {
  it("signature takes a normalized prefix of the first line", () => {
    expect(promptSignature("Fix the   login bug\nand add a test", 24)).toBe("fix the login bug");
  });

  it("signature skips leading blank lines", () => {
    expect(promptSignature("\n\n  Implement caching  \n", 24)).toBe("implement caching");
  });

  it("signature is capped to maxLen", () => {
    expect(promptSignature("abcdefghijklmnopqrstuvwxyz", 10)).toBe("abcdefghij");
  });

  it("signature of a blank prompt is empty", () => {
    expect(promptSignature("   \n\t ")).toBe("");
  });

  it("region matches across box padding and case", () => {
    const box = "╭───────────────╮\n│ > Fix the   LOGIN bug      │\n╰───────────────╯";
    expect(regionContains(box, promptSignature("fix the login bug"))).toBe(true);
  });

  it("region reports the prompt gone after submit", () => {
    const emptyBox = "╭───────────────╮\n│ >                          │\n╰───────────────╯";
    expect(regionContains(emptyBox, promptSignature("fix the login bug"))).toBe(false);
  });

  it("empty signature never matches", () => {
    expect(regionContains("anything at all", "")).toBe(false);
  });
});
