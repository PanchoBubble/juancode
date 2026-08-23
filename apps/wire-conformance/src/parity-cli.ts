// Regenerate a parity checklist from a status file, or check a checked-in status
// file against a fresh measurement.
//
//   pnpm --filter @juancode/wire-conformance parity            # every status file
//   pnpm --filter @juancode/wire-conformance parity rust       # just one core
//   pnpm --filter @juancode/wire-conformance parity --verify m.json
//
// The markdown is always generated, so the checklist can never drift from the
// scenario registry. That is NOT enough on its own: it is generated FROM the
// status JSON, so a status JSON whose measurement is out of date regenerates
// cleanly and reports a stale score as fresh. `--verify` is the half that closes
// that: it compares the committed status file against a status file a real run
// just wrote, and fails when the claim and the measurement disagree.

import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { renderParityMarkdown, statusDifferences, writeText, type StatusFile } from "./report.ts";
import { loadScenarios } from "./spec.ts";

const here = dirname(fileURLToPath(import.meta.url));
const PARITY_DIR = join(here, "..", "parity");

function read(path: string): StatusFile {
  return JSON.parse(readFileSync(path, "utf8")) as StatusFile;
}

/** Compare a fresh measurement against the checked-in claim for the same core. */
function verify(measuredPath: string): void {
  const measured = read(resolve(measuredPath));
  const committedPath = join(PARITY_DIR, `${measured.core}-status.json`);
  const committed = read(committedPath);
  const diffs = statusDifferences(committed, measured);
  if (diffs.length === 0) {
    console.log(
      `parity/${measured.core}-status.json still describes the core (measured ${measured.measuredAt})`,
    );
    return;
  }
  console.error(`parity/${measured.core}-status.json no longer describes the core:`);
  for (const line of diffs) console.error(`  - ${line}`);
  console.error(
    "\nRe-measure and commit it:\n" +
      `  JUANCODE_CONFORMANCE_CORE=${measured.core} JUANCODE_CONFORMANCE_STATUS=parity/${measured.core}-status.json \\\n` +
      "    pnpm --filter @juancode/wire-conformance test:conformance\n" +
      `  pnpm --filter @juancode/wire-conformance parity ${measured.core}`,
  );
  process.exit(1);
}

function regenerate(only: string[]): void {
  const scenarios = loadScenarios();
  const files = readdirSync(PARITY_DIR)
    .filter((f) => f.endsWith("-status.json"))
    .filter((f) => only.length === 0 || only.some((core) => f.startsWith(`${core}-`)));
  if (files.length === 0) {
    console.error(
      `no status files in ${PARITY_DIR}${only.length ? ` matching ${only.join(", ")}` : ""}`,
    );
    process.exit(1);
  }
  for (const file of files) {
    const status = read(join(PARITY_DIR, file));
    const unknown = Object.keys(status.scenarios).filter(
      (id) => !scenarios.some((s) => s.id === id),
    );
    if (unknown.length) {
      console.error(`${file}: status for unknown scenarios: ${unknown.join(", ")}`);
      process.exit(1);
    }
    const out = join(PARITY_DIR, `${status.core}-core.md`);
    writeText(out, renderParityMarkdown(scenarios, status));
    const unmet = scenarios.filter((s) => status.scenarios[s.id]?.status !== "passed").length;
    console.log(`wrote ${out} (${unmet} of ${scenarios.length} scenarios unmet)`);
  }
}

function main(): void {
  const args = process.argv.slice(2);
  const verifyAt = args.indexOf("--verify");
  if (verifyAt !== -1) {
    const path = args[verifyAt + 1];
    if (!path) {
      console.error("--verify needs the path of a status file a run just wrote");
      process.exit(1);
    }
    verify(path);
    return;
  }
  regenerate(args);
}

main();
