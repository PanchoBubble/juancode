// The link between the spec and the cores' sources of truth.
//
// A spec that is merely "documentation" rots the first time someone adds a
// message. So the spec is compared against the cores directly: add a client
// message, a server message, or a capability to either one and this test goes red
// until spec/v1/protocol.json describes it (and, ideally, a scenario covers it).
//
// The catalogue is the UNION of what the cores speak, not a mirror of one of them
// (see the CATALOGUE_IS_THE_UNION rule in protocol.json). What says which core
// speaks a message is its capability gate, so each core is measured against the
// messages its own advertised capability list entails:
//
//   * nothing off the catalogue - a type a core speaks that this file does not
//     describe is drift, whichever core grew it;
//   * no empty promises - a capability a core advertises must come with every
//     frame its gate names, because clients feature-detect off exactly that.
//
// Neither half asks a core to grow a decode case, or an encoder it would never
// use, for a capability it does not advertise. The rule this replaced compared the
// catalogue to WireProtocol.swift alone, which is why `editQueued` and the three
// transcript frames were implemented, advertised and unlistable - and therefore
// unmeasurable, since a golden transcript may only reference catalogued types.

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { loadProtocol, loadScenarios, expectedTypes, sentTypes } from "./spec.ts";

const here = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(here, "..", "..", "..");

/** A capability a core implements in full and deliberately does not advertise,
 *  plus the types that would be catalogued the day it does. */
interface Withheld {
  capability: string;
  types: string[];
  why: string;
}

/** One core's wire source, and how to read the four things out of it. */
interface CoreProbe {
  name: string;
  path: string;
  clientTypes(src: string): string[];
  serverTypes(src: string): string[];
  capabilities(src: string): string[];
  version(src: string): number | null;
  /** Every field name this core's decoder can actually READ off a client frame.
   *  Type-level drift is not the only kind: `isolateWorktree` was catalogued,
   *  sent by the dispatcher, and absent from the Rust decoder's struct, so serde
   *  dropped it and the daemon ran the agent in the shared checkout while still
   *  answering `created` (juancode-yiho). A type check cannot see that; this can. */
  clientFields(src: string): string[];
  /** Frames behind a capability this core withholds. Exempt from the
   *  nothing-off-the-catalogue check for exactly as long as it stays withheld. */
  withheld: Withheld[];
}

/** `isolateWorktree` -> `isolate_worktree`: the Rust decoder spells a field either
 *  way, as a serde rename or as the struct field the rename is on. */
function snake(field: string): string {
  return field.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);
}

/** Identifiers and string literals in a slice of source, as a set. Tokenised rather
 *  than substring-matched so a short field name (`pr`) cannot be satisfied by an
 *  unrelated word that contains it (`provider`). */
function tokens(src: string): Set<string> {
  return new Set([...src.matchAll(/[A-Za-z_][A-Za-z0-9_]*/g)].map((m) => m[0] as string));
}

const SWIFT: CoreProbe = {
  name: "swift",
  path: join(REPO_ROOT, "apps", "native", "Sources", "JuancodeServer", "WireProtocol.swift"),
  /** Client types the decoder recognises: `case "attach":` in its switch. */
  clientTypes: (src) => {
    const decoder = src.slice(src.indexOf("extension ClientMessage: Decodable"));
    return [...decoder.matchAll(/^\s*case "([a-zA-Z]+)":/gm)].map((m) => m[1] as string);
  },
  /** Server types the encoder emits: `try c.encode("attached", forKey: .type)`. */
  serverTypes: (src) =>
    [...src.matchAll(/encode\("([a-zA-Z]+)", forKey: \.type\)/g)].map((m) => m[1] as string),
  capabilities: (src) => {
    const line = /static let capabilities = \[([^\]]*)\]/.exec(src);
    if (!line) return [];
    return [...(line[1] as string).matchAll(/"([^"]+)"/g)].map((m) => m[1] as string);
  },
  version: (src) => {
    const m = /static let version = (\d+)/.exec(src);
    return m ? Number(m[1]) : null;
  },
  /** `private enum K: String, CodingKey { case type, provider, ... }`: a key that is
   *  not in there cannot be read, whatever the switch below it does. */
  clientFields: (src) => {
    const start = src.indexOf("extension ClientMessage: Decodable");
    const keys = src.slice(start, src.indexOf("public init(from decoder", start));
    return [...tokens(keys)];
  },
  withheld: [],
};

const RUST: CoreProbe = {
  name: "rust",
  path: join(REPO_ROOT, "apps", "juancoded", "crates", "juancoded-server", "src", "wire.rs"),
  /** Client types the decoder recognises: `"attach" => Ok(Self::Attach {` in its
   *  match. Sliced to the decode fn so the module's own tests, which are full of
   *  frame literals, cannot contribute a type nothing decodes. */
  clientTypes: (src) => {
    const decoder = src.slice(
      src.indexOf("pub fn decode"),
      src.indexOf("impl From<&str> for ClientMessage"),
    );
    return [...decoder.matchAll(/^\s*"([a-zA-Z]+)" =>/gm)].map((m) => m[1] as string);
  },
  /** Server types the encoder emits: `"type": "attached"` inside `to_value`.
   *  Sliced for the same reason, and more sharply: a test asserting on a CLIENT
   *  frame literal would otherwise read as a server frame this core encodes. */
  serverTypes: (src) => {
    const encoder = src.slice(src.indexOf("pub fn to_value"), src.indexOf("#[cfg(test)]"));
    return [...encoder.matchAll(/"type":\s*"([a-zA-Z]+)"/g)].map((m) => m[1] as string);
  },
  capabilities: (src) => {
    const line = /pub const CAPABILITIES: &\[&str\] = &\[([^\]]*)\]/.exec(src);
    if (!line) return [];
    return [...(line[1] as string).matchAll(/"([^"]+)"/g)].map((m) => m[1] as string);
  },
  version: (src) => {
    const m = /pub const PROTOCOL_VERSION: u32 = (\d+)/.exec(src);
    return m ? Number(m[1]) : null;
  },
  /** `struct RawClient` alone, and deliberately not the decode fn below it: the
   *  struct is the only thing serde reads, and the enum variant in `decode` names
   *  the same field again, so a slice that included it would still find the name
   *  after the struct had lost it. */
  clientFields: (src) => {
    const start = src.indexOf("struct RawClient");
    return [...tokens(src.slice(start, src.indexOf("impl ClientMessage", start)))];
  },
  withheld: [
    {
      capability: "contributions",
      types: [
        "subscribeContributions",
        "unsubscribeContributions",
        "activateContribution",
        "contributions",
        "contributionResult",
      ],
      why: "the daemon side is complete but nothing renders a descriptor yet, so advertising it would promise chrome nothing draws",
    },
  ],
};

const PROBES: CoreProbe[] = [SWIFT, RUST];

function sourceOf(probe: CoreProbe): string | null {
  return existsSync(probe.path) ? readFileSync(probe.path, "utf8") : null;
}

const spec = loadProtocol();

/** The messages a core advertising `caps` has promised to implement: everything
 *  ungated, plus everything gated by a capability it advertises. */
function entailedBy(caps: string[], messages: Record<string, { capability?: string }>): string[] {
  return Object.entries(messages)
    .filter(([, m]) => m.capability === undefined || caps.includes(m.capability))
    .map(([type]) => type);
}

/** Types this core may speak without cataloguing them, because the capability
 *  behind them is one it does not advertise. Advertising it removes the exemption,
 *  which is what makes the catalogue catch the frames on the day they go public. */
function exempt(probe: CoreProbe, caps: string[]): string[] {
  return probe.withheld.filter((w) => !caps.includes(w.capability)).flatMap((w) => w.types);
}

describe.each(PROBES)("the $name core against the catalogue", (probe) => {
  const src = sourceOf(probe);
  const caps = src ? probe.capabilities(src) : [];

  it.runIf(src)("speaks no client message this catalogue does not describe", () => {
    const spoken = [...new Set(probe.clientTypes(src as string))];
    // A regex that matched nothing would make every subset check below pass.
    expect(spoken.length, "the client-type regex found nothing").toBeGreaterThan(10);
    const allowed = new Set([...Object.keys(spec.clientMessages), ...exempt(probe, caps)]);
    expect(spoken.filter((t) => !allowed.has(t))).toEqual([]);
  });

  it.runIf(src)("speaks no server message this catalogue does not describe", () => {
    const spoken = [...new Set(probe.serverTypes(src as string))];
    expect(spoken.length, "the server-type regex found nothing").toBeGreaterThan(10);
    const allowed = new Set([...Object.keys(spec.serverMessages), ...exempt(probe, caps)]);
    expect(spoken.filter((t) => !allowed.has(t))).toEqual([]);
  });

  it.runIf(src)("implements every message its advertised capabilities entail", () => {
    // The half a client depends on: it switches a feature on because the core said
    // the capability's name, so every frame that gate covers has to be answered.
    const client = new Set(probe.clientTypes(src as string));
    const server = new Set(probe.serverTypes(src as string));
    expect(entailedBy(caps, spec.clientMessages).filter((t) => !client.has(t))).toEqual([]);
    expect(entailedBy(caps, spec.serverMessages).filter((t) => !server.has(t))).toEqual([]);
  });

  it.runIf(src)("can read every field of every message it has promised to run", () => {
    // The other half of "no empty promises", one level down. A core answers a frame
    // whose optional field it never decodes with the same `created` it would send
    // for a frame that carried the field, so the client is told the operation it
    // asked for happened. `isolateWorktree` is why this test exists: catalogued,
    // sent by the Oracle dispatcher, and absent from the Rust decoder's struct, so
    // every isolated dispatch ran in the shared checkout and reported started
    // (juancode-yiho). Gated fields are exempt for as long as the gate is: a core
    // that does not advertise `spawnModel` has promised nothing about `create.model`.
    const readable = new Set(probe.clientFields(src as string));
    expect(readable.size, "the client-field reader found nothing").toBeGreaterThan(5);
    const missing: string[] = [];
    for (const [type, msg] of Object.entries(spec.clientMessages)) {
      if (msg.capability !== undefined && !caps.includes(msg.capability)) continue;
      for (const field of [...msg.required, ...msg.optional]) {
        const gate = msg.fieldCapabilities?.[field];
        if (gate !== undefined && !caps.includes(gate)) continue;
        if (!readable.has(field) && !readable.has(snake(field))) missing.push(`${type}.${field}`);
      }
    }
    expect(missing, "catalogued, entailed, and silently dropped").toEqual([]);
  });

  it.runIf(src)("advertises only capabilities the catalogue knows", () => {
    expect(caps.length).toBeGreaterThan(0);
    for (const cap of caps) expect(spec.capabilities.known).toContain(cap);
  });

  it.runIf(src)("agrees on the protocol version", () => {
    expect(probe.version(src as string)).toBe(spec.protocolVersion);
  });
});

describe("the catalogue against the cores", () => {
  // The other direction, and the one the per-core checks cannot cover on their own:
  // each of those measures a core against the subset the catalogue gates onto it, so
  // an invented message gated by an invented capability would be nobody's problem.
  // It is everybody's here.
  const sources = PROBES.map((probe) => ({ probe, src: sourceOf(probe) })).filter(
    (p): p is { probe: CoreProbe; src: string } => p.src !== null,
  );
  const complete = sources.length === PROBES.length;

  it.runIf(complete)("describes no message neither core implements", () => {
    const spoken = new Set(
      sources.flatMap(({ probe, src }) => [...probe.clientTypes(src), ...probe.serverTypes(src)]),
    );
    const orphans = [...Object.keys(spec.clientMessages), ...Object.keys(spec.serverMessages)]
      .filter((t) => !spoken.has(t))
      .sort();
    expect(orphans, "catalogued but implemented by no core").toEqual([]);
  });

  it.runIf(complete)("knows no capability neither core advertises", () => {
    const advertised = new Set(sources.flatMap(({ probe, src }) => probe.capabilities(src)));
    expect(spec.capabilities.known.filter((c) => !advertised.has(c))).toEqual([]);
  });
});

describe("scenario coverage", () => {
  const scenarios = loadScenarios();
  const asserted = new Set(scenarios.flatMap(expectedTypes));
  const driven = new Set(scenarios.flatMap(sentTypes));

  it("asserts every server message except the ones documented as uncovered", () => {
    // `trackNotification` needs a real GitHub event to fire, so no scenario can
    // provoke it from a socket alone; it is on the parity checklist instead.
    const uncovered = ["trackNotification"];
    for (const type of Object.keys(spec.serverMessages)) {
      if (uncovered.includes(type)) continue;
      expect(asserted, `no scenario asserts a ${type} frame`).toContain(type);
    }
  });

  it("drives every client message except the ones documented as undriven", () => {
    // `resolveTrackNotification` can only be sent for a notification that exists,
    // which needs the GitHub event above.
    const undriven = ["resolveTrackNotification"];
    for (const type of Object.keys(spec.clientMessages)) {
      if (undriven.includes(type)) continue;
      expect(driven, `no scenario sends a ${type} frame`).toContain(type);
    }
  });
});
