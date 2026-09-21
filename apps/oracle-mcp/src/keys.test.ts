import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { KEY_NAMES, keyBytes, keyBytesFor, unknownKey, unknownKeyMessage } from "./keys.ts";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

describe("the named-key vocabulary", () => {
  it("resolves each name to the bytes a terminal reads it as", () => {
    expect(keyBytes("Enter")).toEqual([0x0d]);
    expect(keyBytes("Escape")).toEqual([0x1b]);
    expect(keyBytes("Tab")).toEqual([0x09]);
    expect(keyBytes("Backspace")).toEqual([0x7f]);
    expect(keyBytes("Space")).toEqual([0x20]);
    expect(keyBytes("Up")).toEqual([0x1b, 0x5b, 0x41]);
    expect(keyBytes("Down")).toEqual([0x1b, 0x5b, 0x42]);
    expect(keyBytes("Right")).toEqual([0x1b, 0x5b, 0x43]);
    expect(keyBytes("Left")).toEqual([0x1b, 0x5b, 0x44]);
  });

  it("makes every control letter its position in the alphabet", () => {
    expect(keyBytes("C-a")).toEqual([0x01]);
    expect(keyBytes("C-c")).toEqual([0x03]);
    expect(keyBytes("C-d")).toEqual([0x04]);
    expect(keyBytes("C-z")).toEqual([0x1a]);
  });

  it("is forgiving about spelling, because a phone keyboard is not", () => {
    expect(keyBytes("ESCAPE")).toEqual(keyBytes("escape"));
    expect(keyBytes("esc")).toEqual(keyBytes("Escape"));
    expect(keyBytes("return")).toEqual(keyBytes("Enter"));
    expect(keyBytes("ctrl-c")).toEqual(keyBytes("C-c"));
    expect(keyBytes("  Up  ")).toEqual(keyBytes("Up"));
  });

  it("rejects an unknown name rather than letting it through as text", () => {
    // The failure this whole path exists to end: "Excape" typed into an agent's
    // prompt box is a worse answer than an error.
    for (const bad of ["Excape", "C-", "C-cc", "C-1", ""]) expect(keyBytes(bad)).toBeNull();
    expect(unknownKey(["Up", "Excape", "Enter"])).toBe("Excape");
    expect(unknownKey(["Up", "Enter"])).toBeNull();
    expect(unknownKeyMessage("Excape")).toContain("Escape");
  });

  it("resolves a batch in order, and refuses one with a bad name whole", () => {
    expect([...keyBytesFor(["Up", "Enter"])].map((c) => c.charCodeAt(0))).toEqual([
      0x1b, 0x5b, 0x41, 0x0d,
    ]);
    expect(() => keyBytesFor(["Up", "Excape"])).toThrow(/Excape/);
  });

  it("offers the whole vocabulary the ticket asked for", () => {
    expect(KEY_NAMES).toHaveLength(9 + 26);
    for (const name of ["Enter", "Escape", "Tab", "Backspace", "Space", "Up", "Down", "Left", "Right", "C-a", "C-c", "C-d", "C-z"]) {
      expect(KEY_NAMES).toContain(name);
    }
  });
});

// ── The mirror ───────────────────────────────────────────────────────────────
// Two implementations of one table (this one and the core's) is two chances to
// drift, and the symptom of drift is a phone button that does nothing, or the wrong
// thing. So the core's source is read directly and compared, the way
// apps/wire-conformance/src/drift.test.ts compares the protocol catalogue.
//
// There were three until juancode-nqpm: the Swift core had its own `NamedKey.swift`,
// and it went with the core. The list below is still a list because the check is
// worth keeping table-shaped — a second core would be added back here.

/** `("enter", &[0x0D]),` parses to name/bytes pairs with one regex per core. */
function parseTable(src: string, pattern: RegExp): Record<string, number[]> {
  const out: Record<string, number[]> = {};
  for (const m of src.matchAll(pattern)) {
    out[m[1] as string] = (m[2] as string)
      .split(",")
      .map((b) => b.trim())
      .filter((b) => b.length > 0)
      .map((b) => Number(b));
  }
  return out;
}

const CORES = [
  {
    name: "rust",
    path: join(
      REPO_ROOT,
      "apps",
      "juancoded",
      "crates",
      "juancoded-server",
      "src",
      "named_key.rs",
    ),
    table: /\("([a-z-]+)", &\[([^\]]+)\]\)/g,
    aliases: /\("([a-z-]+)", "([a-z-]+)"\)/g,
  },
];

describe.each(CORES)("the sidecar table against the $name core's", (core) => {
  const src = readFileSync(core.path, "utf8");

  it("names the same keys and the same bytes", () => {
    const theirs = parseTable(src, core.table);
    // A regex that matched nothing would make the comparison vacuous.
    expect(Object.keys(theirs).length).toBe(9);
    for (const [name, bytes] of Object.entries(theirs)) {
      expect(keyBytes(name), `${core.name} knows ${name}`).toEqual(bytes);
    }
    // And the other direction: a name only this side knows would send a `key` frame
    // the core answers with an error.
    for (const name of KEY_NAMES.filter((n) => !n.startsWith("C-"))) {
      expect(Object.keys(theirs), `${core.name} is missing ${name}`).toContain(name.toLowerCase());
    }
  });

  it("accepts the same aliases", () => {
    const pairs: [string, string][] = [...src.matchAll(core.aliases)].map((m) => [
      m[1] as string,
      m[2] as string,
    ]);
    // A regex that matched nothing would make the comparison vacuous.
    expect(pairs.length).toBeGreaterThan(0);
    for (const [alias, canonical] of pairs) {
      expect(keyBytes(alias), `alias ${alias}`).toEqual(keyBytes(canonical));
    }
  });

  it("derives the control letters the same way", () => {
    // Both cores compute C-a … C-z from the letter's position rather than listing
    // them, so the mirror check is on the rule, not on 26 literals.
    expect(src).toMatch(/a['"]?\s*\+\s*1|1 \+ i/);
  });
});
