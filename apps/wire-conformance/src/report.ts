// Reports.
//
// Two shapes, one input. A RUN report says what happened when the suite drove a
// core (that is what CI uploads). A PARITY checklist is the checked-in artifact
// derived from it: the list of scenarios a core does not satisfy yet, which is
// the work list for making it satisfy them.

import { writeFileSync } from "node:fs";

import type { Outcome } from "./runner.ts";
import type { Scenario } from "./spec.ts";

/** "unknown" is for a status file seeded by reading a core rather than running the
 *  suite against it: honest about not having measured, and counted as unmet. */
export type Status = "passed" | "failed" | "skipped" | "unknown";

export interface RunReport {
  /** Short core name, e.g. "swift" or "rust". */
  core: string;
  url: string;
  specRevision: string;
  protocolVersion: number | null;
  capabilities: string[];
  /** Attempts each scenario was asked for (JUANCODE_CONFORMANCE_REPEAT). */
  repeat: number;
  outcomes: Outcome[];
}

export interface ScenarioStatus {
  status: Status;
  note?: string;
  /** How many attempts the verdict is based on, and how many of them passed.
   *  Absent on a file written before the counts existed, or seeded by reading a
   *  core rather than running it; such a verdict renders as a bare mark. */
  attempts?: number;
  passes?: number;
}

export interface StatusFile {
  core: string;
  coreLabel: string;
  /** "measured" = written by a real run; "source-read" = seeded by reading the core. */
  source: "measured" | "source-read";
  measuredAt: string;
  specRevision: string;
  protocolVersion: number | null;
  capabilities: string[];
  scenarios: Record<string, ScenarioStatus>;
}

/** What a core is called in a checklist header. A re-measure rewrites the status
 *  file wholesale, so the readable name has to live here or every measurement
 *  quietly replaces it with the short one. */
const CORE_LABELS: Record<string, string> = {
  swift: "apps/native (JuancodeServer), the Swift core",
  rust: "apps/juancoded, the Rust core",
};

export function toStatusFile(report: RunReport, measuredAt: string): StatusFile {
  const scenarios: Record<string, ScenarioStatus> = {};
  for (const o of report.outcomes) {
    scenarios[o.scenarioId] =
      o.status === "passed"
        ? { status: "passed", attempts: o.attempts, passes: o.passes }
        : o.status === "skipped"
          ? { status: "skipped", note: o.reason }
          : {
              status: "failed",
              note: firstLine(o.error),
              attempts: o.attempts,
              passes: o.passes,
            };
  }
  return {
    core: report.core,
    coreLabel: CORE_LABELS[report.core] ?? report.core,
    source: "measured",
    measuredAt,
    specRevision: report.specRevision,
    protocolVersion: report.protocolVersion,
    capabilities: report.capabilities,
    scenarios,
  };
}

/** Where a checked-in status file and a fresh measurement disagree, as lines a
 *  human can act on. Empty means the committed file still describes the core.
 *
 * Only the CLAIM is compared: the spec revision, the protocol version, the
 * advertised capabilities and each scenario's verdict. The measurement date moves
 * every day and a failure note carries a temp path, so comparing those would fail
 * a run that agrees about everything that matters. The attempt counts are left out
 * for the same reason: CI measures each scenario three times and a developer
 * re-measuring locally once agrees with it about every verdict. */
export function statusDifferences(committed: StatusFile, measured: StatusFile): string[] {
  const diffs: string[] = [];
  if (committed.specRevision !== measured.specRevision) {
    diffs.push(
      `spec revision: committed ${committed.specRevision}, measured ${measured.specRevision}`,
    );
  }
  if (committed.protocolVersion !== measured.protocolVersion) {
    diffs.push(
      `protocol version: committed ${committed.protocolVersion}, measured ${measured.protocolVersion}`,
    );
  }
  const committedCaps = [...committed.capabilities].sort();
  const measuredCaps = [...measured.capabilities].sort();
  if (committedCaps.join(",") !== measuredCaps.join(",")) {
    diffs.push(
      `capabilities: committed [${committedCaps.join(", ")}], measured [${measuredCaps.join(", ")}]`,
    );
  }
  const ids = [
    ...new Set([...Object.keys(committed.scenarios), ...Object.keys(measured.scenarios)]),
  ].sort();
  for (const id of ids) {
    const was = committed.scenarios[id]?.status ?? "absent";
    const now = measured.scenarios[id]?.status ?? "absent";
    if (was !== now) diffs.push(`${id}: committed ${was}, measured ${now}`);
  }
  return diffs;
}

function firstLine(text: string): string {
  return (text.split("\n")[0] ?? text).slice(0, 300);
}

const MARK: Record<Status, string> = {
  passed: "yes",
  failed: "NO",
  skipped: "n/a",
  unknown: "not measured",
};

/** A verdict plus how many measurements it rests on: "3/3", or "NO (1/3)".
 *
 *  A ratio rather than a bare "yes" because a checked-in checklist is read as the
 *  gate, and twice a one-run green has been reported as one and turned out not to
 *  be repeatable. A file measured once still reads honestly, as 1/1. */
export function mark(status: Status, attempts?: number, passes?: number): string {
  if (attempts === undefined || passes === undefined) return MARK[status];
  if (status === "passed") return `${passes}/${attempts}`;
  if (status === "failed") return `${MARK.failed} (${passes}/${attempts})`;
  return MARK[status];
}

/** How many attempts the verdicts in a status file rest on, for the header. One
 *  number when the whole file was measured in one run, which is the normal case. */
function attemptsBehind(status: StatusFile): string {
  const counts = new Set(
    Object.values(status.scenarios)
      .map((st) => st.attempts)
      .filter((n): n is number => typeof n === "number"),
  );
  if (counts.size === 0) return "not recorded";
  if (counts.size === 1) return `${[...counts][0]} per scenario`;
  return `${Math.min(...counts)} to ${Math.max(...counts)} per scenario`;
}

function markOf(st: ScenarioStatus | undefined): string {
  return st ? mark(st.status, st.attempts, st.passes) : "never measured";
}

export function renderRunMarkdown(report: RunReport, at: string): string {
  const counts = { passed: 0, failed: 0, skipped: 0 };
  for (const o of report.outcomes) counts[o.status] += 1;
  const lines: string[] = [
    `# Wire conformance run: ${report.core}`,
    "",
    `- Spec revision: ${report.specRevision} (protocol v${report.protocolVersion ?? "?"})`,
    `- Core: ${report.url}`,
    `- Capabilities: ${report.capabilities.join(", ") || "none advertised"}`,
    `- Run at: ${at}`,
    `- Attempts per scenario: ${report.repeat} (JUANCODE_CONFORMANCE_REPEAT)`,
    `- Result: ${counts.passed} passed, ${counts.failed} failed, ${counts.skipped} skipped`,
    "",
    "## Scenarios",
    "",
  ];
  for (const o of report.outcomes) {
    const detail =
      o.status === "failed" ? firstLine(o.error) : o.status === "skipped" ? o.reason : "";
    const verdict = o.status === "skipped" ? MARK.skipped : mark(o.status, o.attempts, o.passes);
    lines.push(`- ${o.scenarioId}: ${verdict}${detail ? ` - ${oneLine(detail)}` : ""}`);
  }
  lines.push("");
  return lines.join("\n");
}

export function renderParityMarkdown(scenarios: Scenario[], status: StatusFile): string {
  const unmet = scenarios.filter((s) => status.scenarios[s.id]?.status !== "passed");
  const lines: string[] = [
    `# Wire-protocol parity checklist: ${status.coreLabel}`,
    "",
    "Generated by `pnpm --filter @juancode/wire-conformance parity`. Do not hand-edit:",
    "edit `parity/<core>-status.json` (or re-measure, see the package README) and regenerate.",
    "",
    `- Spec revision: ${status.specRevision} (protocol v${status.protocolVersion ?? "?"})`,
    `- Status source: ${status.source === "measured" ? "a real conformance run" : "reading the core's source"}`,
    `- Attempts behind each verdict: ${attemptsBehind(status)}`,
    `- As of: ${status.measuredAt}`,
    `- Capabilities the core advertises: ${status.capabilities.join(", ") || "none"}`,
    `- Unmet scenarios: ${unmet.length} of ${scenarios.length}`,
    "",
    `## What is not satisfied yet (${unmet.length})`,
    "",
  ];
  if (unmet.length === 0) {
    lines.push("Nothing: this core passes every scenario in the spec.", "");
  } else {
    for (const s of unmet) {
      const st = status.scenarios[s.id];
      const needs = [...(s.capabilities ?? []), ...(s.requires ?? [])].join(", ") || "core basics";
      lines.push(
        `### ${s.id}`,
        "",
        `- Status: ${markOf(st)}`,
        `- Needs: ${needs}`,
        `- Why: ${oneLine(st?.note ?? "never measured")}`,
        `- Asserts: ${oneLine(s.asserts)}`,
        "",
      );
    }
  }
  lines.push("## Full scenario list", "");
  for (const s of scenarios) {
    const st = status.scenarios[s.id];
    lines.push(`- ${s.id}: ${markOf(st)} - ${oneLine(s.title)}`);
  }
  lines.push("");
  return lines.join("\n");
}

/** Collapse to one line: a report is read as a list, so an embedded newline in a
 *  failure message would break the item it belongs to. */
function oneLine(text: string): string {
  return text.replace(/\s*\n\s*/g, " ").trim();
}

export function writeText(path: string, text: string): void {
  writeFileSync(path, text);
}
