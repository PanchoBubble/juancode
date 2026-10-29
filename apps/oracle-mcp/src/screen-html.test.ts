import { describe, expect, it } from "vitest";
import { escapeHtml, segmentHtml } from "./screen-html.ts";

describe("segmentHtml", () => {
  it("passes plain text through unwrapped, escaped", () => {
    expect(segmentHtml({ text: "hi" })).toBe("hi");
    expect(segmentHtml({ text: '<b x="1">&' })).toBe("&lt;b x=&quot;1&quot;&gt;&amp;");
  });

  it("escapes text inside styled spans too", () => {
    expect(segmentHtml({ text: "<x>", fg: 1 })).toBe(
      '<span style="color:#cd0000">&lt;x&gt;</span>',
    );
  });
});

describe("escapeHtml", () => {
  it("escapes the four HTML-sensitive characters", () => {
    expect(escapeHtml('&<>"plain')).toBe("&amp;&lt;&gt;&quot;plain");
  });
});
