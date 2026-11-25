// The short RESULT block every dispatched child ends with. Notifications carry
// only this block instead of the child's whole last message.
export const RESULT_CONTRACT = `When you finish, end your final message with exactly this block (max 15 lines):
RESULT
status: done|blocked|question
changed: what changed (files, commit sha)
verified: how you verified it
ticket: <ticket id or none>`;

const MAX_LINES = 15;
const MAX_CHARS = 1500;

/** The last `RESULT` block in `text` (a line of just `RESULT`, followed by a
 *  `status:` line), capped; null when the child did not follow the contract. */
export function extractResultBlock(text: string): string | null {
  const lines = text.split("\n");
  const start = lines.findLastIndex((l) => /^[\s*#]*RESULT[\s*:]*$/.test(l));
  if (start < 0) return null;
  const block = lines
    .slice(start, start + MAX_LINES)
    .map((l) => l.trimEnd())
    .join("\n")
    .trim();
  return /^status:/im.test(block) ? block.slice(0, MAX_CHARS) : null;
}
