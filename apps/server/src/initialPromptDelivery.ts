/**
 * Pure helpers for confirming a seeded prompt is delivered into a CLI's input box
 * (see {@link Session.autoSubmit}). Split out so the brittle text-matching — the
 * part most likely to drift as `claude`/`codex` change their TUI wording — is
 * unit-testable without spinning up a real pty. Mirrors
 * `apps/native/Sources/JuancodeCore/InitialPromptDelivery.swift`.
 */

/**
 * A distinctive, normalized token taken from the start of `prompt`, used to find
 * the prompt in — or confirm it has left — the input box. We take the first
 * non-empty line (the box reflows long/multi-line text, so only the first
 * rendered row is reliably contiguous) and keep a short prefix so the signature
 * stays within a single wrapped box row. Returns "" for an all-whitespace prompt;
 * an empty signature never matches (see {@link regionContains}).
 */
export function promptSignature(prompt: string, maxLen = 24): string {
  const firstLine = prompt.split(/[\r\n]/).find((l) => l.trim() !== "");
  if (firstLine === undefined) return "";
  return normalize(firstLine).slice(0, maxLen);
}

/**
 * True if `signature` appears in `screenRegion`. Both sides are whitespace-
 * collapsed and lowercased first, so the box's padding/borders and the prompt's
 * own spacing don't defeat the match. An empty signature never matches.
 */
export function regionContains(screenRegion: string, signature: string): boolean {
  const sig = normalize(signature);
  if (!sig) return false;
  return normalize(screenRegion).includes(sig);
}

/**
 * Lowercase and collapse every run of whitespace (incl. newlines) to a single
 * space, trimming the ends — the canonical form both sides are compared in.
 */
function normalize(s: string): string {
  return s.toLowerCase().replace(/\s+/g, " ").trim();
}
