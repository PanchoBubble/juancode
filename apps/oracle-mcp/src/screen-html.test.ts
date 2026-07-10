import { describe, expect, it } from "vitest";
import { DEFAULT_BG, DEFAULT_FG, ansi256, escapeHtml, rowHtml, segmentHtml } from "./screen-html.ts";

describe("ansi256", () => {
  it("maps the base-16 palette", () => {
    expect(ansi256(0)).toBe("#000000");
    expect(ansi256(1)).toBe("#cd0000");
    expect(ansi256(15)).toBe("#ffffff");
  });

  it("maps the 6x6x6 color cube", () => {
    expect(ansi256(16)).toBe("#000000");
    expect(ansi256(196)).toBe("#ff0000");
    expect(ansi256(46)).toBe("#00ff00");
    expect(ansi256(231)).toBe("#ffffff");
  });

  it("maps the grayscale ramp", () => {
    expect(ansi256(232)).toBe("#080808");
    expect(ansi256(255)).toBe("#eeeeee");
  });

  it("falls back to the default fg for out-of-range input", () => {
    expect(ansi256(-1)).toBe(DEFAULT_FG);
    expect(ansi256(256)).toBe(DEFAULT_FG);
    expect(ansi256(1.5)).toBe(DEFAULT_FG);
  });
});

describe("segmentHtml", () => {
  it("passes plain text through unwrapped, escaped", () => {
    expect(segmentHtml({ text: "hi" })).toBe("hi");
    expect(segmentHtml({ text: '<b x="1">&' })).toBe("&lt;b x=&quot;1&quot;&gt;&amp;");
  });

  it("escapes text inside styled spans too", () => {
    expect(segmentHtml({ text: "<x>", fg: 1 })).toBe('<span style="color:#cd0000">&lt;x&gt;</span>');
  });

  it("renders ANSI-index and truecolor fg/bg", () => {
    expect(segmentHtml({ text: "a", fg: 2, bg: 0 })).toBe(
      '<span style="color:#00cd00;background:#000000">a</span>',
    );
    expect(segmentHtml({ text: "a", fg: "#123456" })).toBe('<span style="color:#123456">a</span>');
  });

  it('resolves "inv" to the opposite default', () => {
    expect(segmentHtml({ text: "a", fg: "inv" })).toBe(`<span style="color:${DEFAULT_BG}">a</span>`);
    expect(segmentHtml({ text: "a", bg: "inv" })).toBe(`<span style="background:${DEFAULT_FG}">a</span>`);
  });

  it("renders the style bitmask", () => {
    // 1 bold + 2 underline + 64 italic + 128 strikethrough + 32 dim
    expect(segmentHtml({ text: "a", st: 1 | 2 | 32 | 64 | 128 })).toBe(
      '<span style="font-weight:700;opacity:.55;font-style:italic;text-decoration:underline line-through">a</span>',
    );
  });

  it("inverse swaps colors, using the defaults when unset", () => {
    expect(segmentHtml({ text: "a", st: 8 })).toBe(
      `<span style="color:${DEFAULT_BG};background:${DEFAULT_FG}">a</span>`,
    );
    expect(segmentHtml({ text: "a", fg: 1, bg: 4, st: 8 })).toBe(
      '<span style="color:#0000ee;background:#cd0000">a</span>',
    );
  });

  it("invisible overrides the foreground with transparent", () => {
    expect(segmentHtml({ text: "a", fg: 1, st: 16 })).toBe(
      '<span style="color:#cd0000;color:transparent">a</span>',
    );
  });

  it("ignores the blink bit", () => {
    expect(segmentHtml({ text: "a", st: 4 })).toBe("a");
  });
});

describe("rowHtml", () => {
  it("joins segments and keeps blank rows empty", () => {
    expect(rowHtml([])).toBe("");
    expect(rowHtml([{ text: "a" }, { text: "b", st: 1 }])).toBe(
      'a<span style="font-weight:700">b</span>',
    );
  });
});

describe("escapeHtml", () => {
  it("escapes the four HTML-sensitive characters", () => {
    expect(escapeHtml('&<>"plain')).toBe("&amp;&lt;&gt;&quot;plain");
  });
});
