// Capability negotiation, including the refusal path.
//
// The whole point of `serverInfo` is that a client can decide, before it sends
// anything, whether this core can host it. Two cores with different capability
// lists is a supported configuration; a client that assumes parity is the bug.
// So the contract has two halves and both are tested: a compatible core is
// accepted, and an incompatible one is REFUSED rather than driven blind.

import type { ServerInfo } from "./client.ts";

export interface ClientRequirements {
  /** Protocol versions this client speaks. A core outside the set is refused. */
  protocolVersions: number[];
  /** Capabilities the client cannot work without. */
  required: string[];
  /** Capabilities the client uses when present and hides when absent. */
  optional?: string[];
}

export type Negotiation =
  | { ok: true; version: number; enabled: string[]; disabled: string[] }
  | { ok: false; reason: string; missing: string[]; versionMismatch: boolean };

/** Decide whether a client can drive this core, and which optional features to
 *  light up. Pure: the same handshake always yields the same verdict. */
export function negotiate(info: ServerInfo, want: ClientRequirements): Negotiation {
  const versionMismatch = !want.protocolVersions.includes(info.protocolVersion);
  const advertised = new Set(info.capabilities);
  const missing = want.required.filter((c) => !advertised.has(c));

  if (versionMismatch) {
    return {
      ok: false,
      reason:
        `core speaks wire protocol v${info.protocolVersion}; this client speaks ` +
        `v${want.protocolVersions.join(", v")}`,
      missing,
      versionMismatch: true,
    };
  }
  if (missing.length) {
    return {
      ok: false,
      reason: `core is missing required capabilities: ${missing.join(", ")}`,
      missing,
      versionMismatch: false,
    };
  }
  const optional = want.optional ?? [];
  return {
    ok: true,
    version: info.protocolVersion,
    enabled: [...want.required, ...optional.filter((c) => advertised.has(c))],
    disabled: optional.filter((c) => !advertised.has(c)),
  };
}

/** What the conformance suite itself needs from a core to run the scenarios that
 *  are not capability-gated. Mirrors `protocol.json.capabilities.required`. */
export const SUITE_REQUIREMENTS: ClientRequirements = {
  protocolVersions: [1],
  required: ["inputAck", "resizeAck", "screen"],
  optional: ["queue", "trackedPrs", "editor", "terminal", "adoptExternal"],
};
