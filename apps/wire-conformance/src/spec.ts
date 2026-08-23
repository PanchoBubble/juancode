// Loader and types for the versioned wire spec under `spec/`.
//
// The spec is data, not code: `spec/v<protocolVersion>/protocol.json` is the
// message catalogue and `spec/v<n>/scenarios/*.json` are the golden transcripts.
// A core is conformant at version N when it passes every scenario in `spec/vN`.

import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

/** Root of the checked-in spec (repo path, not a build artifact). */
export const SPEC_ROOT = join(here, "..", "spec");

/** The only protocol version with a spec today. Bump alongside `WireProtocol.version`. */
export const SPEC_VERSION = 1;

export interface MessageSpec {
  required: string[];
  optional: string[];
  /** Capability that gates this message; absent means every core must implement it. */
  capability?: string;
  /** Capabilities that gate single optional FIELDS of an otherwise ungated message
   *  (`create.model`). A core without one still answers the message, minus the field. */
  fieldCapabilities?: Record<string, string>;
  notes?: string;
}

export interface ProtocolSpec {
  specRevision: string;
  protocolVersion: number;
  source: string;
  transport: Record<string, unknown>;
  capabilities: {
    required: string[];
    known: string[];
    /** capability -> the message `type`s it gates, or `type.field` for a field gate. */
    gates: Record<string, string[]>;
    notes?: string;
  };
  clientMessages: Record<string, MessageSpec>;
  serverMessages: Record<string, MessageSpec>;
  enums: Record<string, string[]>;
  sessionMeta: { required: string[]; optional: string[] };
  rules: string[];
  /** Operations deliberately NOT given a frame, and why. Here so the next person
   *  to hit the gap reads the decision instead of rediscovering the question. */
  decisions?: Record<string, string>;
}

/** A frame matcher plus what to bind out of it (see match.ts). */
export interface ExpectStep {
  expect: Record<string, unknown>;
  on?: string;
  timeoutMs?: number;
  bind?: Record<string, string>;
  /** Frame types this step tolerates in between, overriding the scenario's list. */
  ignore?: string[];
  note?: string;
}

export type Step =
  /** Open a connection. `keep: true` leaves its handshake and connect-time
   *  broadcasts in the stream, for a transcript that asserts what a client sees
   *  the moment it arrives. */
  | { open: string; keep?: boolean; note?: string }
  /** Close a connection mid-scenario. The only way to drive a core's
   *  disconnect-side behaviour (releasing the grids that client owned). */
  | { close: string; note?: string }
  | { send: Record<string, unknown>; on?: string; note?: string }
  | { raw: string; on?: string; note?: string }
  | ExpectStep
  | { expectFirstFrame: Record<string, unknown>; on?: string; note?: string }
  | { expectHandshake: Record<string, unknown>; on?: string; note?: string }
  | { expectNone: Record<string, unknown>; withinMs?: number; on?: string; note?: string }
  | { sleep: number; note?: string };

/** Environment a scenario needs beyond a bare core: a pty child, git, gh. */
export type Requirement = "pty" | "git" | "gh";

export interface Scenario {
  id: string;
  title: string;
  /** One sentence: what conformance to this scenario buys a client. */
  asserts: string;
  /** Capabilities a core must advertise; a core without them is reported skipped. */
  capabilities?: string[];
  requires?: Requirement[];
  /** Present when the scenario cannot run in GitHub Actions, with the reason. */
  skipInCI?: string;
  /** Frame types this scenario does not constrain (async chatter). */
  ignore?: string[];
  steps: Step[];
}

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

export function loadProtocol(version = SPEC_VERSION): ProtocolSpec {
  return readJson<ProtocolSpec>(join(SPEC_ROOT, `v${version}`, "protocol.json"));
}

export function loadScenarios(version = SPEC_VERSION): Scenario[] {
  const dir = join(SPEC_ROOT, `v${version}`, "scenarios");
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => readJson<Scenario>(join(dir, f)));
}

/** Every frame type a scenario expects, for the coverage check in spec.test.ts. */
export function expectedTypes(scenario: Scenario): string[] {
  const out: string[] = [];
  for (const step of scenario.steps) {
    const matcher =
      "expect" in step
        ? step.expect
        : "expectFirstFrame" in step
          ? step.expectFirstFrame
          : "expectHandshake" in step
            ? step.expectHandshake
            : null;
    const type = matcher?.type;
    if (typeof type === "string") out.push(type);
  }
  return out;
}

/** Every client frame type a scenario sends. */
export function sentTypes(scenario: Scenario): string[] {
  const out: string[] = [];
  for (const step of scenario.steps) {
    if ("send" in step && typeof step.send.type === "string") out.push(step.send.type);
  }
  return out;
}
