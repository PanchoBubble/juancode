// The named control keys a remote surface can send into a session (juancode-uigs).
//
// THE ONE PLACE in this sidecar that spells an escape sequence. Telegram, the phone
// console and the HTTP route all pass NAMES; nothing above this file knows that
// Escape is 0x1b or that Up is ESC [ A, so learning a key is one edit and there is no
// second definition of the protocol to drift from.
//
// The cores own the same table — apps/native/Sources/JuancodeServer/NamedKey.swift and
// apps/juancoded/crates/juancoded-server/src/named_key.rs — and the `key` wire frame
// carries names, so on a core advertising `namedKeys` the bytes here are never sent.
// They exist for two jobs: refusing an unknown name before it reaches the wire, and
// the fallback for a core too old to know the frame, where the bytes go out as a plain
// `input` (never bracketed-pasted — the paste wrapper is what makes input literal, and
// is the whole reason a keystroke could not be sent remotely before this).
//
// keys.test.ts compares this table against both cores' sources directly, so a key
// added on one side turns the suite red until every side agrees.

/** The canonical vocabulary, name → the bytes a terminal reads it as.
 *
 *  Arrows are the NORMAL-mode (CSI) forms, not the application-cursor (`ESC O A`)
 *  ones: no client can know which mode the pty is in, and both prompt TUIs here accept
 *  CSI either way. */
const NAMED: Record<string, number[]> = {
  enter: [0x0d],
  escape: [0x1b],
  tab: [0x09],
  backspace: [0x7f],
  space: [0x20],
  up: [0x1b, 0x5b, 0x41],
  down: [0x1b, 0x5b, 0x42],
  right: [0x1b, 0x5b, 0x43],
  left: [0x1b, 0x5b, 0x44],
};

/** Spellings that mean a canonical name. Tiny on purpose: every alias is one more
 *  thing three implementations have to carry. */
const ALIASES: Record<string, string> = { esc: "escape", return: "enter" };

const LETTERS = "abcdefghijklmnopqrstuvwxyz";

/** `c-c` → `C-c`, `escape` → `Escape`: the spelling the vocabulary is documented in. */
function canonicalCase(lower: string): string {
  if (lower.startsWith("c-")) return "C-" + lower.slice(2);
  return lower.slice(0, 1).toUpperCase() + lower.slice(1);
}

/** The canonical vocabulary, sorted — what an error lists and what a UI offers.
 *  Aliases are deliberately absent: they resolve, they are not the spelling to learn. */
export const KEY_NAMES: string[] = [
  ...Object.keys(NAMED),
  ...[...LETTERS].map((c) => `c-${c}`),
]
  .sort()
  .map(canonicalCase);

/** The bytes `name` stands for, or null when it is not a key any core knows.
 *  Case-insensitive, and `ctrl-c` resolves wherever `C-c` is spelled. */
export function keyBytes(name: string): number[] | null {
  let key = name.trim().toLowerCase();
  if (key.startsWith("ctrl-")) key = "c-" + key.slice("ctrl-".length);
  if (ALIASES[key]) key = ALIASES[key] as string;
  if (NAMED[key]) return [...(NAMED[key] as number[])];
  // C-a … C-z are 0x01 … 0x1a: the letter's position in the alphabet. Computed rather
  // than listed so the 26 cannot disagree with each other.
  const letter = key.startsWith("c-") ? key.slice(2) : "";
  const at = letter.length === 1 ? LETTERS.indexOf(letter) : -1;
  return at >= 0 ? [at + 1] : null;
}

/** The name of the first key in `names` that no core knows, or null when they all
 *  resolve. Batches are all or nothing: a half-applied `Up, Up, Enter` answers a
 *  permission prompt on the wrong row, which is worse than not answering it. */
export function unknownKey(names: string[]): string | null {
  for (const name of names) if (keyBytes(name) === null) return name;
  return null;
}

/** The whole batch as the bytes to write, for the fallback path only. Throws on an
 *  unknown name — callers validate with {@link unknownKey} first and say so nicely. */
export function keyBytesFor(names: string[]): string {
  let out = "";
  for (const name of names) {
    const bytes = keyBytes(name);
    if (!bytes) throw new Error(`Unknown key "${name}"`);
    out += bytes.map((b) => String.fromCharCode(b)).join("");
  }
  return out;
}

/** The message an unknown name earns: names it, then lists what does resolve. */
export function unknownKeyMessage(name: string): string {
  return `Unknown key "${name}". Known keys: ${KEY_NAMES.join(", ")}`;
}
