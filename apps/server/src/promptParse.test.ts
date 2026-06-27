import { describe, expect, it } from "vitest";
import { parsePrompt } from "./promptParse.ts";

describe("parsePrompt", () => {
  it("parses a Claude permission menu with a cursor and an (esc) hint", () => {
    const screen = [
      "  Bash(rm -rf build)",
      "",
      "  Do you want to proceed?",
      "❯ 1. Yes",
      "  2. Yes, and don't ask again this session",
      "  3. No, and tell Claude what to do differently (esc)",
      "",
    ].join("\n");
    const prompt = parsePrompt(screen);
    expect(prompt).not.toBeNull();
    expect(prompt!.question).toBe("Do you want to proceed?");
    expect(prompt!.options).toEqual([
      { index: 1, label: "Yes" },
      { index: 2, label: "Yes, and don't ask again this session" },
      { index: 3, label: "No, and tell Claude what to do differently" },
    ]);
  });

  it("parses a menu framed in box-drawing borders", () => {
    const screen = [
      "╭─────────────────────────────╮",
      "│ Allow Edit to config.ts?    │",
      "│ ❯ 1. Allow                  │",
      "│   2. Deny                   │",
      "╰─────────────────────────────╯",
    ].join("\n");
    const prompt = parsePrompt(screen);
    expect(prompt!.question).toContain("Allow Edit to config.ts?");
    expect(prompt!.options.map((o) => o.label)).toEqual(["Allow", "Deny"]);
  });

  it("falls back to the question line for a plain yes/no prompt with no menu", () => {
    const screen = ["Some output", "Overwrite existing file? (y/n)", ""].join("\n");
    const prompt = parsePrompt(screen);
    expect(prompt!.question).toBe("Overwrite existing file? (y/n)");
    expect(prompt!.options).toEqual([]);
  });

  it("dedupes repeated option indices from a repaint and sorts them", () => {
    const screen = ["Pick one", "  2. Two", "❯ 1. One", "  1. One", "  2. Two"].join("\n");
    const prompt = parsePrompt(screen);
    expect(prompt!.options).toEqual([
      { index: 1, label: "One" },
      { index: 2, label: "Two" },
    ]);
  });

  it("returns null when there is no question and no menu", () => {
    expect(parsePrompt("just some\nregular output\n")).toBeNull();
  });
});
