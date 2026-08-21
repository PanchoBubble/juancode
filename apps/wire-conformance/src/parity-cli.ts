// Regenerate a parity checklist from a status file.
//
//   pnpm --filter @juancode/wire-conformance parity            # every status file
//   pnpm --filter @juancode/wire-conformance parity rust       # just one core
//
// The status file is either hand-seeded from reading a core's source or written
// by a real run (see the package README). The markdown is always generated, so
// the checklist can never drift from the scenario registry.

import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { renderParityMarkdown, writeText, type StatusFile } from "./report.ts";
import { loadScenarios } from "./spec.ts";

const here = dirname(fileURLToPath(import.meta.url));
const PARITY_DIR = join(here, "..", "parity");

function main(): void {
  const only = process.argv.slice(2);
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
    const status = JSON.parse(readFileSync(join(PARITY_DIR, file), "utf8")) as StatusFile;
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

main();
