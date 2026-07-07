import { describe, expect, it } from "vitest";
import {
  promptSignature,
  regionContains,
  regionShowsCollapsedPaste,
} from "./initialPromptDelivery.ts";

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

  it("detects Claude's collapsed-paste chip (large/multi-line paste)", () => {
    const box = "╭───────────────╮\n│ > [Pasted text #1 +29 lines]  │\n╰───────────────╯";
    expect(regionShowsCollapsedPaste(box)).toBe(true);
    // The literal first line never renders, so the signature can't match — the chip
    // is the only proof the paste landed.
    expect(regionContains(box, promptSignature("Implement the new billing module"))).toBe(false);
  });

  it("does not see a paste chip in an ordinary input box", () => {
    const box = "╭───────────────╮\n│ > Fix the login bug        │\n╰───────────────╯";
    expect(regionShowsCollapsedPaste(box)).toBe(false);
  });
});
