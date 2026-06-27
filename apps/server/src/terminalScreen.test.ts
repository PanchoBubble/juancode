import { describe, expect, it } from "vitest";
import { TerminalScreen } from "./terminalScreen.ts";

/** Mirrors apps/native/Tests/JuancodeCoreTests/TerminalScreenTests.swift. */
describe("TerminalScreen", () => {
  it("writes plain text", () => {
    const s = new TerminalScreen(20, 4);
    s.feed("hello world");
    expect(s.visibleText).toBe("hello world");
  });

  it("carriage return overwrites", () => {
    const s = new TerminalScreen(20, 4);
    s.feed("hello\rH");
    expect(s.visibleText).toBe("Hello");
  });

  it("newline moves down, keeping the column (CRLF resets it)", () => {
    const s = new TerminalScreen(20, 4);
    s.feed("a\r\nb");
    expect(s.visibleText).toBe("a\nb");
  });

  it("absolute cursor positioning", () => {
    const s = new TerminalScreen(20, 4);
    s.feed("\x1b[2;3HX"); // row 2, col 3 (1-based)
    expect(s.visibleText).toBe("\n  X");
  });

  it("erase-line clears it", () => {
    const s = new TerminalScreen(20, 2);
    s.feed("abcdef\r");
    s.feed("\x1b[K");
    expect(s.visibleText).toBe("");
  });

  it("erase to end from cursor", () => {
    const s = new TerminalScreen(20, 2);
    s.feed("abcdef");
    s.feed("\x1b[3G"); // col 3 (1-based) → index 2
    s.feed("\x1b[K");
    expect(s.visibleText).toBe("ab");
  });

  it("clears the screen", () => {
    const s = new TerminalScreen(10, 3);
    s.feed("line1\r\nline2");
    s.feed("\x1b[2J");
    expect(s.visibleText).toBe("");
  });

  it("scrolls on overflow", () => {
    const s = new TerminalScreen(10, 2);
    s.feed("a\r\nb\r\nc"); // 'a' scrolls off the top
    expect(s.visibleText).toBe("b\nc");
  });

  it("buffers an escape split across feeds", () => {
    const s = new TerminalScreen(20, 2);
    s.feed("X\x1b[2"); // incomplete CSI — must be held
    s.feed("3GY"); // completes to ESC[23G (col 23 → clamped to 19), then Y
    const line = s.visibleText;
    expect(line.startsWith("X")).toBe(true);
    expect(line.endsWith("Y")).toBe(true);
  });

  it("isolates the alternate screen", () => {
    const s = new TerminalScreen(10, 2);
    s.feed("main");
    s.feed("\x1b[?1049h"); // enter alt screen (cleared)
    expect(s.visibleText).toBe("");
    s.feed("alt");
    expect(s.visibleText).toBe("alt");
    s.feed("\x1b[?1049l"); // back to main, preserved
    expect(s.visibleText).toBe("main");
  });

  it("leaves spatial gaps for cursor moves (words not glued)", () => {
    const s = new TerminalScreen(40, 2);
    s.feed("esc\x1b[20Gto\x1b[30Ginterrupt");
    const t = s.visibleText;
    expect(t).toContain("esc");
    expect(t).toContain("interrupt");
    expect(t).not.toContain("esctointerrupt");
  });

  it("preserves content on resize", () => {
    const s = new TerminalScreen(20, 4);
    s.feed("hello");
    s.resize(40, 6);
    expect(s.visibleText).toBe("hello");
  });

  it("rows() returns one trimmed entry per grid row (stable for diffing)", () => {
    const s = new TerminalScreen(10, 3);
    s.feed("ab\r\ncd");
    const rows = s.rows();
    expect(rows).toHaveLength(3); // always `height` entries, not trimmed away
    expect(rows[0]).toBe("ab");
    expect(rows[1]).toBe("cd");
    expect(rows[2]).toBe(""); // trailing blank row kept, trailing spaces trimmed
  });
});
