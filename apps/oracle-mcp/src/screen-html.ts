// Renders `screen` frame segments (see native-events.ts ScreenSegment) to HTML
// for the console's read-only live session view. Runs server-side so the browser
// only patches innerHTML per row — no client-side terminal emulator, and all
// escaping/styling stays in one testable place.

import type { ScreenSegment } from "./native-events.ts";

// The console's live-view panel colors — keep in sync with the .live-screen CSS
// in ui.ts. "inv" segments and the inverse style bit resolve against these.
export const DEFAULT_FG = "#d6dbe5";
export const DEFAULT_BG = "#0b0e14";

const STYLE_BOLD = 1;
const STYLE_UNDERLINE = 2;
const STYLE_INVERSE = 8;
const STYLE_INVISIBLE = 16;
const STYLE_DIM = 32;
const STYLE_ITALIC = 64;
const STYLE_STRIKETHROUGH = 128;
// STYLE_BLINK (4) is deliberately not rendered.

/** Standard xterm 16-color base palette; indices 16–255 are computed. */
const BASE16 = [
  "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
  "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
];

const hex2 = (n: number): string => n.toString(16).padStart(2, "0");

/** ANSI-256 index → CSS hex color (base 16, 6×6×6 cube, grayscale ramp). */
export function ansi256(n: number): string {
  if (!Number.isInteger(n) || n < 0 || n > 255) return DEFAULT_FG;
  if (n < 16) return BASE16[n]!;
  if (n < 232) {
    const c = n - 16;
    const level = (v: number): number => (v === 0 ? 0 : v * 40 + 55);
    const r = level(Math.floor(c / 36));
    const g = level(Math.floor((c % 36) / 6));
    const b = level(c % 6);
    return `#${hex2(r)}${hex2(g)}${hex2(b)}`;
  }
  const gray = 8 + (n - 232) * 10;
  return `#${hex2(gray)}${hex2(gray)}${hex2(gray)}`;
}

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
}

/** Resolve a segment color: ANSI index, "#rrggbb" passthrough, or "inv" — the
 *  opposite default (passed by the caller). Absent = null (inherit the panel). */
function resolveColor(v: number | string | undefined, invertedDefault: string): string | null {
  if (typeof v === "number") return ansi256(v);
  if (v === "inv") return invertedDefault;
  if (typeof v === "string") return v;
  return null;
}

/** One segment → escaped text, wrapped in a styled span only when needed. */
export function segmentHtml(seg: ScreenSegment): string {
  const text = escapeHtml(seg.text);
  const st = seg.st ?? 0;
  let fg = resolveColor(seg.fg, DEFAULT_BG);
  let bg = resolveColor(seg.bg, DEFAULT_FG);
  if (st & STYLE_INVERSE) [fg, bg] = [bg ?? DEFAULT_BG, fg ?? DEFAULT_FG];

  const css: string[] = [];
  if (fg) css.push(`color:${fg}`);
  if (bg) css.push(`background:${bg}`);
  if (st & STYLE_BOLD) css.push("font-weight:700");
  if (st & STYLE_DIM) css.push("opacity:.55");
  if (st & STYLE_ITALIC) css.push("font-style:italic");
  const deco: string[] = [];
  if (st & STYLE_UNDERLINE) deco.push("underline");
  if (st & STYLE_STRIKETHROUGH) deco.push("line-through");
  if (deco.length) css.push(`text-decoration:${deco.join(" ")}`);
  if (st & STYLE_INVISIBLE) css.push("color:transparent");

  if (!css.length) return text;
  return `<span style="${css.join(";")}">${text}</span>`;
}

/** One row's segments → its innerHTML. Empty segs = a blank row ("" — the
 *  console keeps the row box via CSS min-height). */
export function rowHtml(segs: ScreenSegment[]): string {
  return segs.map(segmentHtml).join("");
}
