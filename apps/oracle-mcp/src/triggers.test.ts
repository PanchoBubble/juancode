import { describe, expect, it, vi } from "vitest";
import {
  EMPTY_TRIGGER_CONFIG,
  fireTrigger,
  handleLabelEvent,
  labelDispatchRequest,
  labelPrompt,
  matchLabelRule,
  normalizeTriggerConfig,
  projectAllowed,
  ticketPrompt,
  triggersDisabledByEnv,
  type LabelEvent,
  type TriggerConfig,
} from "./triggers.ts";
import type { DispatchOutcome } from "./dispatch.ts";
import type { TriggerOrigin } from "./dispatch-registry.ts";

const ALLOWED = "/Users/me/repos/juancode";

function config(over: Partial<TriggerConfig> = {}): TriggerConfig {
  return { ...EMPTY_TRIGGER_CONFIG, allowedProjects: [ALLOWED], ...over };
}

const outcome = (): DispatchOutcome => ({
  dispatchId: "d1",
  started: true,
  queued: false,
  sessionId: "s1",
  message: "Started claude session s1.",
});

const origin: TriggerOrigin = { kind: "schedule", id: "nightly", detail: "schedule nightly" };

describe("triggersDisabledByEnv", () => {
  it("is off by default and on for the falsy spellings", () => {
    expect(triggersDisabledByEnv({})).toBe(false);
    expect(triggersDisabledByEnv({ JUANCODE_TRIGGERS: "1" })).toBe(false);
    expect(triggersDisabledByEnv({ JUANCODE_TRIGGERS: "yes" })).toBe(false);
    for (const v of ["0", "false", "no", "off", "OFF", " 0 ", ""]) {
      expect(triggersDisabledByEnv({ JUANCODE_TRIGGERS: v })).toBe(true);
    }
  });
});

describe("projectAllowed", () => {
  it("refuses everything when the allow list is empty", () => {
    expect(projectAllowed(ALLOWED, [])).toBe(false);
  });

  it("allows the exact repo and a path inside it", () => {
    expect(projectAllowed(ALLOWED, [ALLOWED])).toBe(true);
    expect(projectAllowed(`${ALLOWED}/apps/native`, [ALLOWED])).toBe(true);
  });

  it("refuses a sibling whose path merely shares a prefix", () => {
    expect(projectAllowed("/Users/me/repos/juancode-evil", [ALLOWED])).toBe(false);
  });

  it("refuses a relative path and a traversal out of an allowed root", () => {
    expect(projectAllowed("repos/juancode", [ALLOWED])).toBe(false);
    expect(projectAllowed(`${ALLOWED}/../secrets`, [ALLOWED])).toBe(false);
  });
});

describe("normalizeTriggerConfig", () => {
  it("drops a schedule with a bad cron and says why", () => {
    const cfg = normalizeTriggerConfig({
      allowedProjects: [ALLOWED],
      schedules: [
        { id: "good", cron: "0 3 * * *", project: ALLOWED, prompt: "hi" },
        { id: "bad", cron: "0 99 * * *", project: ALLOWED, prompt: "hi" },
      ],
    });
    expect(cfg.schedules.map((s) => s.id)).toEqual(["good"]);
    expect(cfg.problems.join(" ")).toMatch(/schedule "bad" has a bad cron/);
  });

  it("drops schedules missing an id, a project, or any work to do", () => {
    const cfg = normalizeTriggerConfig({
      allowedProjects: [ALLOWED],
      schedules: [
        { cron: "0 3 * * *", project: ALLOWED, prompt: "x" },
        { id: "rel", cron: "0 3 * * *", project: "repos/x", prompt: "x" },
        { id: "empty", cron: "0 3 * * *", project: ALLOWED },
      ],
    });
    expect(cfg.schedules).toEqual([]);
    expect(cfg.problems).toHaveLength(3);
  });

  it("defaults worktree on and keeps a ticket schedule", () => {
    const cfg = normalizeTriggerConfig({
      allowedProjects: [ALLOWED],
      schedules: [{ id: "t", cron: "0 3 * * *", project: ALLOWED, ticket: "juancode-1" }],
    });
    expect(cfg.schedules[0]).toMatchObject({ worktree: true, ticket: "juancode-1", enabled: true });
  });

  it("refuses a non-absolute allowedProjects entry", () => {
    const cfg = normalizeTriggerConfig({ allowedProjects: ["./repos"] });
    expect(cfg.allowedProjects).toEqual([]);
    expect(cfg.problems.join(" ")).toMatch(/not an absolute path/);
  });

  it("reads the master switch and label rules", () => {
    const cfg = normalizeTriggerConfig({
      enabled: false,
      allowedProjects: [ALLOWED],
      repos: { "Owner/Repo": ALLOWED },
      labels: [{ repo: "Owner/Repo", label: "agent:fix" }],
    });
    expect(cfg.enabled).toBe(false);
    expect(cfg.repos).toEqual({ "owner/repo": ALLOWED });
    expect(cfg.labels).toHaveLength(1);
  });

  it("survives a non-object config", () => {
    expect(normalizeTriggerConfig("nope").schedules).toEqual([]);
    expect(normalizeTriggerConfig(null).problems).toEqual(["config is not a JSON object"]);
  });
});

describe("fireTrigger", () => {
  it("dispatches an allowed project and tags the origin", async () => {
    const run = vi.fn(async () => outcome());
    const result = await fireTrigger({ project: ALLOWED, prompt: "go" }, origin, config(), {
      dispatch: run,
      env: {},
    });
    expect(result).toEqual({ fired: true, outcome: outcome() });
    expect(run).toHaveBeenCalledWith(expect.objectContaining({ trigger: origin }));
  });

  it("refuses a project outside the allow list without dispatching", async () => {
    const run = vi.fn(async () => outcome());
    const result = await fireTrigger(
      { project: "/Users/me/repos/other", prompt: "go" },
      origin,
      config(),
      { dispatch: run, env: {} },
    );
    expect(result).toEqual({ fired: false, reason: expect.stringContaining("allow list") });
    expect(run).not.toHaveBeenCalled();
  });

  it("refuses when the env kill switch is set", async () => {
    const run = vi.fn(async () => outcome());
    const result = await fireTrigger({ project: ALLOWED, prompt: "go" }, origin, config(), {
      dispatch: run,
      env: { JUANCODE_TRIGGERS: "0" },
    });
    expect(result).toEqual({ fired: false, reason: expect.stringContaining("JUANCODE_TRIGGERS") });
    expect(run).not.toHaveBeenCalled();
  });

  it("refuses when the config's own switch is off", async () => {
    const run = vi.fn(async () => outcome());
    const result = await fireTrigger(
      { project: ALLOWED, prompt: "go" },
      origin,
      config({ enabled: false }),
      { dispatch: run, env: {} },
    );
    expect(result.fired).toBe(false);
    expect(run).not.toHaveBeenCalled();
  });

  it("turns a rejected dispatch into a reason rather than throwing", async () => {
    const result = await fireTrigger({ project: ALLOWED, prompt: "go" }, origin, config(), {
      dispatch: async () => {
        throw new Error("no such provider");
      },
      env: {},
    });
    expect(result).toEqual({ fired: false, reason: "no such provider" });
  });
});

describe("label rules", () => {
  const ev: LabelEvent = {
    repo: "Owner/Repo",
    label: "agent:fix",
    number: 12,
    title: "Flaky test",
    branch: "fix/flake",
    url: "https://github.com/Owner/Repo/pull/12",
    isPr: true,
  };

  const withLabels = () =>
    config({
      repos: { "owner/repo": ALLOWED },
      labels: [{ repo: "Owner/Repo", label: "agent:fix", worktree: true, enabled: true }],
    });

  it("matches case-insensitively and resolves the repo path", () => {
    const match = matchLabelRule(withLabels(), { ...ev, repo: "owner/REPO", label: "Agent:Fix" });
    expect(match?.project).toBe(ALLOWED);
  });

  it("does not match a different label, a disabled rule, or an unmapped repo", () => {
    expect(matchLabelRule(withLabels(), { ...ev, label: "other" })).toBeNull();
    const disabled = config({
      repos: { "owner/repo": ALLOWED },
      labels: [{ repo: "Owner/Repo", label: "agent:fix", enabled: false }],
    });
    expect(matchLabelRule(disabled, ev)).toBeNull();
    const unmapped = config({ labels: [{ repo: "Owner/Repo", label: "agent:fix" }] });
    expect(matchLabelRule(unmapped, ev)).toBeNull();
  });

  it("builds a worktree dispatch whose prompt names the branch", () => {
    const match = matchLabelRule(withLabels(), ev)!;
    const { request, origin: o } = labelDispatchRequest(match, ev);
    expect(request).toMatchObject({ project: ALLOWED, provider: "claude", worktree: true });
    expect(request.prompt).toContain("fix/flake");
    expect(request.prompt).toContain("#12");
    expect(o).toEqual({
      kind: "label",
      id: "Owner/Repo#agent:fix",
      detail: 'label "agent:fix" on Owner/Repo#12',
    });
  });

  it("fills a custom prompt template", () => {
    const rendered = labelPrompt(
      { repo: "Owner/Repo", label: "agent:fix", prompt: "{repo}#{number} on {branch}: {title}" },
      ev,
    );
    expect(rendered).toBe("Owner/Repo#12 on fix/flake: Flaky test");
  });

  it("says worktree-off-the-default-branch for a plain issue", () => {
    const prompt = labelPrompt(
      { repo: "Owner/Repo", label: "agent:fix" },
      { ...ev, isPr: false, branch: null },
    );
    expect(prompt).toContain("default branch");
    expect(prompt).toContain("gh issue view 12");
  });

  it("handleLabelEvent fires through the allow list", async () => {
    const run = vi.fn(async () => outcome());
    const result = await handleLabelEvent(ev, {
      readConfig: async () => withLabels(),
      dispatch: run,
      env: {},
    });
    expect(result.fired).toBe(true);
    expect(run).toHaveBeenCalledWith(
      expect.objectContaining({
        project: ALLOWED,
        trigger: expect.objectContaining({ kind: "label" }),
      }),
    );
  });

  it("handleLabelEvent ignores a label with no rule", async () => {
    const run = vi.fn(async () => outcome());
    const result = await handleLabelEvent(
      { ...ev, label: "wontfix" },
      {
        readConfig: async () => withLabels(),
        dispatch: run,
        env: {},
      },
    );
    expect(result).toEqual({ fired: false, reason: expect.stringContaining("no trigger rule") });
    expect(run).not.toHaveBeenCalled();
  });

  it("handleLabelEvent refuses a rule pointing outside the allow list", async () => {
    const run = vi.fn(async () => outcome());
    const cfg = config({
      allowedProjects: [ALLOWED],
      repos: { "owner/repo": "/Users/me/repos/elsewhere" },
      labels: [{ repo: "Owner/Repo", label: "agent:fix" }],
    });
    const result = await handleLabelEvent(ev, {
      readConfig: async () => cfg,
      dispatch: run,
      env: {},
    });
    expect(result).toEqual({ fired: false, reason: expect.stringContaining("allow list") });
    expect(run).not.toHaveBeenCalled();
  });
});

describe("ticketPrompt", () => {
  it("is self-contained: names the ticket, the schedule and how to read it", () => {
    const prompt = ticketPrompt("juancode-42", "nightly-ready");
    expect(prompt).toContain("juancode-42");
    expect(prompt).toContain("nightly-ready");
    expect(prompt).toContain("bd show juancode-42");
  });
});
