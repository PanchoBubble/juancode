import type { SessionPrompt, PromptOption } from "./protocol.ts";

/**
 * Best-effort extraction of the pending question + selectable options from a
 * waiting_input session's rendered screen, so the UI can offer tappable choices
 * (and a free-text note) on a phone instead of making the user fish around the
 * raw TUI. Only ever called while the session is already classified
 * `waiting_input` (see {@link ActivityDetector.extractPrompt}), so a numbered
 * line here is a menu choice, not prose.
 *
 * The CLIs paint a permission menu like:
 *
 *     Do you want to proceed?
 *     ❯ 1. Yes
 *       2. Yes, and don't ask again this session
 *       3. No, and tell Claude what to do differently (esc)
 *
 * We pull the numbered options and the prose line(s) just above them as the
 * question. For a plain yes/no prompt with no menu we fall back to the prompt
 * line itself and return no options.
 */

/** A numbered menu line, optionally cursored with ❯/›/>. */
const OPTION_RE = /^[❯›>\s]*(\d+)[.)]\s+(.+?)\s*$/;

/** Box-drawing characters the TUI frames its prompts with — noise for our purposes. */
const BORDER_RE = /[│┃╎╏┆┇┊┋╭╮╯╰─━┄┅┈┉┌┐└┘├┤┬┴┼]/g;

/** A line that looks like a question even without a numbered menu. */
const QUESTION_RES: readonly RegExp[] = [
  /\bDo you want to\b/i,
  /\bProceed\?/i,
  /\(y\/n\)/i,
  /\[y\/n\]/i,
  /\bAllow\b.{0,40}\?/i,
  /\?\s*$/,
];

const MAX_LABEL = 120;
const MAX_QUESTION = 240;

function clean(line: string): string {
  return line
    .replace(BORDER_RE, " ")
    .replace(/[^\S\n]+/g, " ")
    .trim();
}

/** Trailing CLI hints like "(esc)" / "(esc to interrupt)" aren't part of the choice. */
function trimHint(label: string): string {
  return label.replace(/\s*\((?:esc|enter|tab|press[^)]*)\)\s*$/i, "").trim();
}

export function parsePrompt(screen: string): SessionPrompt | null {
  const lines = screen.split("\n").map(clean);

  const options: PromptOption[] = [];
  const seen = new Set<number>();
  let firstOptLine = -1;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line === undefined) continue;
    const m = OPTION_RE.exec(line);
    if (!m) continue;
    const index = Number(m[1]);
    const label = trimHint(m[2] ?? "").slice(0, MAX_LABEL);
    if (index < 1 || index > 9 || !label || seen.has(index)) continue;
    if (firstOptLine < 0) firstOptLine = i;
    seen.add(index);
    options.push({ index, label });
  }
  options.sort((a, b) => a.index - b.index);

  // Question: the nearest non-empty prose line(s) above the first option, or —
  // with no menu — the lowest line that reads like a question.
  let question = "";
  if (firstOptLine >= 0) {
    const parts: string[] = [];
    for (let i = firstOptLine - 1; i >= 0 && parts.length < 3; i--) {
      const line = lines[i];
      if (!line) {
        if (parts.length) break; // stop at the blank line above the question block
        continue;
      }
      if (OPTION_RE.test(line)) continue;
      parts.unshift(line);
    }
    question = parts.join(" ").trim();
  } else {
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i];
      if (line && QUESTION_RES.some((re) => re.test(line))) {
        question = line;
        break;
      }
    }
  }
  question = question.slice(0, MAX_QUESTION);

  if (!question && options.length === 0) return null;
  return { question, options };
}
