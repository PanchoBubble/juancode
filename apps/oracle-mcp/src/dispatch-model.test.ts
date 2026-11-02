import { describe, expect, it } from "vitest";
import { isDispatchProvider, selectDispatchModel } from "./dispatch-model.ts";

const select = (prompt: string) => selectDispatchModel({ prompt }, {});
describe("dispatch model routing", () => {
  it("uses a cheaper provider for clearly bounded chores", () => {
    expect(select("Fix the spelling in README.md")).toMatchObject({
      provider: "codex",
      model: "gpt-6-luna",
      complexity: "simple",
    });
  });
  it.each([
    "Implement a new settings panel",
    "Work on ticket juancode-123",
    "Fix a typo and investigate broken authentication",
    "Rename the distributed lock manager",
  ])("avoids under-routing ambiguous or risky work: %s", (prompt) => {
    expect(select(prompt).complexity).not.toBe("simple");
  });
  it("uses the stronger tier for risky changes", () => {
    expect(select("Fix the race condition in session shutdown")).toMatchObject({
      model: "opus",
      complexity: "complex",
    });
  });
  it("honors a caller's assessment and provider pin", () => {
    expect(
      selectDispatchModel(
        { prompt: "ticket abc-123", complexity: "simple", provider: "claude" },
        {},
      ),
    ).toMatchObject({ provider: "claude", model: "haiku" });
    expect(selectDispatchModel({ prompt: "architecture", provider: "codex" }, {})).toMatchObject({
      model: "gpt-6-astra",
    });
  });
  it("preserves model overrides and offers the CLI default", () => {
    expect(selectDispatchModel({ prompt: "Fix typo", model: " custom-model " }, {})).toMatchObject({
      provider: "claude",
      model: "custom-model",
    });
    expect(
      selectDispatchModel({ prompt: "architecture", provider: "codex", model: "default" }, {}),
    ).toMatchObject({ provider: "codex", model: null });
  });
  it("does not invent an OpenCode provider/model", () => {
    expect(selectDispatchModel({ prompt: "Fix typo", provider: "opencode" }, {}).model).toBeNull();
    expect(
      selectDispatchModel(
        { prompt: "Fix typo", provider: "opencode" },
        { JUANCODE_DISPATCH_OPENCODE_SIMPLE_MODEL: "local/small" },
      ).model,
    ).toBe("local/small");
  });
  it("does not invent a kimi provider/model either", () => {
    // Same shape as opencode: kimi's model aliases are opaque and move too fast to
    // pin per complexity, so a dispatch to kimi runs the CLI's own default unless a
    // knob says otherwise.
    const routed = selectDispatchModel({ prompt: "Fix typo", provider: "kimi" }, {});
    expect(routed.model).toBeNull();
    expect(routed.reason).toContain("CLI default");
    expect(
      selectDispatchModel(
        { prompt: "Fix typo", provider: "kimi", complexity: "complex" },
        { JUANCODE_DISPATCH_KIMI_COMPLEX_MODEL: "kimi-latest" },
      ).model,
    ).toBe("kimi-latest");
  });
  it("does not invent a copilot provider/model either", () => {
    // copilot's model catalog depends on the account, so a dispatch to it runs the
    // CLI's own default unless an explicit model or a knob says otherwise.
    const routed = selectDispatchModel({ prompt: "Fix typo", provider: "copilot" }, {});
    expect(routed).toMatchObject({ provider: "copilot", model: null });
    expect(routed.reason).toContain("CLI default");
    expect(
      selectDispatchModel(
        { prompt: "Fix typo", provider: "copilot", complexity: "complex" },
        { JUANCODE_DISPATCH_COPILOT_COMPLEX_MODEL: "gpt-5" },
      ).model,
    ).toBe("gpt-5");
    expect(
      selectDispatchModel({ prompt: "Fix typo", provider: "copilot", model: "gpt-5" }, {}).model,
    ).toBe("gpt-5");
  });
  it("accepts every provider the dispatch endpoint advertises, and nothing else", () => {
    for (const provider of ["claude", "codex", "opencode", "kimi", "copilot"]) {
      expect(isDispatchProvider(provider)).toBe(true);
    }
    for (const bogus of ["gemini", "Copilot", "", undefined, 3]) {
      expect(isDispatchProvider(bogus)).toBe(false);
    }
  });
  it("allows account-specific tier mappings and CLI default", () => {
    expect(
      selectDispatchModel(
        { prompt: "Fix typo" },
        { JUANCODE_DISPATCH_CODEX_SIMPLE_MODEL: "available-model" },
      ).model,
    ).toBe("available-model");
    expect(
      selectDispatchModel(
        { prompt: "Fix typo" },
        { JUANCODE_DISPATCH_CODEX_SIMPLE_MODEL: "default" },
      ).model,
    ).toBeNull();
  });
});
