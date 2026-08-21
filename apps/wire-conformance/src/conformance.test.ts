// The live suite: drive a real core and assert the golden transcripts.
//
//   pnpm --filter @juancode/wire-conformance test:conformance
//     builds and boots the Swift core on its own port and database
//
//   JUANCODE_CONFORMANCE_URL=ws://127.0.0.1:4300/ws JUANCODE_CONFORMANCE_LABEL=rust \
//   pnpm --filter @juancode/wire-conformance test:conformance
//     drives whatever core is at that URL instead
//
// Passing against the Swift core is what proves the spec describes the real
// protocol rather than agreeing with itself.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { WireClient, readServerInfo } from "./client.ts";
import { startCore, type CoreUnderTest } from "./core.ts";
import { negotiate, SUITE_REQUIREMENTS } from "./negotiate.ts";
import { renderRunMarkdown, toStatusFile, writeText, type RunReport } from "./report.ts";
import {
  makeWorkspace,
  runScenario,
  skipReason,
  type Outcome,
  type RunContext,
  type Workspace,
} from "./runner.ts";
import { loadProtocol, loadScenarios, type Requirement } from "./spec.ts";

const spec = loadProtocol();
const scenarios = loadScenarios();

let core: CoreUnderTest;
let workspace: Workspace;
let ctx: RunContext;
let protocolVersion: number | null = null;
const outcomes: Outcome[] = [];

/** What this machine can actually provide a scenario. A pty always (the fake
 *  agent is a shell script); git only if it is installed. `gh` is deliberately
 *  never available: the suite stubs it so no run can reach GitHub. */
function detectAvailable(): Requirement[] {
  const available: Requirement[] = ["pty"];
  try {
    execFileSync("git", ["--version"], { stdio: "ignore" });
    available.push("git");
  } catch {
    // No git: the change-rollup and tracked-PR scenarios report as skipped.
  }
  return available;
}

beforeAll(async () => {
  core = await startCore();
  workspace = makeWorkspace();
  const probe = await WireClient.connect(core.wsUrl, "probe");
  const first = await probe.waitFor({ type: "serverInfo" }, { timeoutMs: 10_000, ignore: ["*"] });
  const info = readServerInfo(first);
  probe.close();
  protocolVersion = info.protocolVersion;
  ctx = {
    wsUrl: core.wsUrl,
    workspace,
    capabilities: info.capabilities,
    available: detectAvailable(),
  };
});

afterAll(async () => {
  const report: RunReport = {
    core: core?.label ?? "unknown",
    url: core?.wsUrl ?? "",
    specRevision: spec.specRevision,
    protocolVersion,
    capabilities: ctx?.capabilities ?? [],
    outcomes,
  };
  const at = new Date().toISOString().slice(0, 10);
  const summary = renderRunMarkdown(report, at);
  const target = process.env.JUANCODE_CONFORMANCE_REPORT;
  if (target) {
    const path = resolve(target);
    if (!existsSync(dirname(path))) mkdirSync(dirname(path), { recursive: true });
    if (path.endsWith(".json")) {
      writeText(path, `${JSON.stringify(toStatusFile(report, at), null, 2)}\n`);
    } else {
      writeText(path, summary);
    }
    console.log(`wire-conformance: wrote ${path}`);
  }
  console.log(summary);
  workspace?.dispose();
  await core?.stop();
});

describe(`wire protocol v${spec.protocolVersion}`, () => {
  it("is a version and capability set this client can speak", () => {
    const verdict = negotiate(
      { protocolVersion: protocolVersion ?? -1, capabilities: ctx.capabilities },
      SUITE_REQUIREMENTS,
    );
    expect(verdict.ok, verdict.ok ? "" : verdict.reason).toBe(true);
  });

  it("is refused by a client that speaks a different protocol version", () => {
    // The refusal path is half the contract: a client MUST be able to decline a
    // core rather than drive one it does not understand.
    const futureClient = {
      protocolVersions: [protocolVersion ?? 1].map((v) => v + 1),
      required: [],
    };
    const verdict = negotiate(
      { protocolVersion: protocolVersion ?? 1, capabilities: ctx.capabilities },
      futureClient,
    );
    expect(verdict.ok).toBe(false);
    if (!verdict.ok) expect(verdict.versionMismatch).toBe(true);
  });

  for (const scenario of scenarios) {
    it(`${scenario.id}: ${scenario.title}`, async (t) => {
      const reason = skipReason(scenario, ctx);
      if (reason) {
        outcomes.push({ status: "skipped", scenarioId: scenario.id, reason });
        t.skip(reason);
        return;
      }
      const started = Date.now();
      try {
        await runScenario(scenario, ctx);
        outcomes.push({ status: "passed", scenarioId: scenario.id, ms: Date.now() - started });
      } catch (e) {
        outcomes.push({
          status: "failed",
          scenarioId: scenario.id,
          ms: Date.now() - started,
          error: e instanceof Error ? e.message : String(e),
        });
        throw e;
      }
    });
  }
});
