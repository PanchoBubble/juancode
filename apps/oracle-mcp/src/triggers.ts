// Triggers: a dispatch that starts without a human typing it (juancode-chhr).
//
// Two sources, one path. A cron schedule (trigger-schedules.ts) and a GitHub
// label (github-webhook.ts) both end up calling `fireTrigger` here, which is a
// thin, guarded wrapper around the same `dispatch()` every human path uses — so
// there is no second spawn mechanism to keep working, and every trigger-started
// session shows up in the dispatch registry, `/api/dispatches`, dispatch-status
// and the Telegram back-channel exactly like a typed one, tagged with where it
// came from.
//
// Three guards, all of them fail-closed:
//
//   1. The kill switch. `JUANCODE_TRIGGERS=0` (also `off`/`false`/`no`) disables
//      every trigger, and so does `"enabled": false` in the config. Both are read
//      at fire time, so flipping the config file takes effect without a restart.
//   2. The allow list. `allowedProjects` is the ONLY thing that makes a repo
//      dispatchable by a trigger. An empty (or missing) list means no trigger can
//      fire anywhere — a config typo silently disables triggers rather than
//      silently widening them.
//   3. No new credentials. Nothing here reads a token the sidecar didn't already
//      hold: schedules are local config, and the label path rides the existing
//      HMAC-verified GitHub webhook. A trigger never calls the GitHub API.
//
// Config lives in `$JUANCODE_ORACLE_DIR/oracle-triggers.json` and is hand-edited;
// it is re-read on every tick and every webhook, so no restart is needed. Runtime
// state (last fire, last session) is written to a SEPARATE file by
// trigger-schedules.ts, so the sidecar never rewrites the human's config.

import { readFile } from "node:fs/promises";
import { isAbsolute, join, resolve, sep } from "node:path";
import { dispatch, type DispatchOutcome, type DispatchRequest } from "./dispatch.ts";
import { cronError } from "./cron.ts";
import { oracleDir } from "./oracle.ts";
import type { TriggerOrigin } from "./dispatch-registry.ts";

export type TriggerProvider = "claude" | "codex" | "opencode";

/** One cron-scheduled dispatch. Either `prompt` or `ticket` must be set. */
export interface ScheduleConfig {
  /** Stable id — the overlap/last-fire state is keyed on it, so don't rename casually. */
  id: string;
  /** 5-field cron expression, evaluated in the Mac's local time. */
  cron: string;
  /** Absolute path of the repo to dispatch into. Must be on `allowedProjects`. */
  project: string;
  prompt?: string;
  /** A bd ticket id; the seed prompt tells the agent to work it end-to-end. */
  ticket?: string;
  provider?: TriggerProvider;
  /** Isolate in a fresh worktree. Defaults to true — a scheduled agent should not
   *  land in the middle of whatever the human has checked out. */
  worktree?: boolean;
  enabled?: boolean;
  /** Ping this Telegram chat with the session's lifecycle events. */
  telegramChatId?: number | null;
}

/** One "issue/PR gained a label → dispatch" rule. */
export interface LabelRuleConfig {
  /** GitHub `owner/name`. Matched case-insensitively. */
  repo: string;
  /** The label whose addition fires the dispatch. Matched case-insensitively. */
  label: string;
  /** Repo → local path, when it isn't in the config's `repos` map. */
  project?: string;
  /** Seed prompt with `{repo} {number} {title} {branch} {url} {label}` placeholders.
   *  Omitted → a default prompt describing the labelled issue/PR. */
  prompt?: string;
  provider?: TriggerProvider;
  /** Defaults to true: a label dispatch works on someone else's branch, so it must
   *  not touch the human's checkout. */
  worktree?: boolean;
  enabled?: boolean;
  telegramChatId?: number | null;
}

export interface TriggerConfig {
  /** Master switch in the config file; the env kill switch overrides it either way. */
  enabled: boolean;
  /** The only repos a trigger may dispatch into. Empty ⇒ nothing fires. */
  allowedProjects: string[];
  /** GitHub `owner/name` → absolute local repo path. */
  repos: Record<string, string>;
  schedules: ScheduleConfig[];
  labels: LabelRuleConfig[];
  /** Human-readable complaints about the file: bad cron, unknown fields, dropped
   *  entries. Surfaced by GET /api/triggers so a typo is visible, not silent. */
  problems: string[];
}

export const EMPTY_TRIGGER_CONFIG: TriggerConfig = {
  enabled: true,
  allowedProjects: [],
  repos: {},
  schedules: [],
  labels: [],
  problems: [],
};

export const triggerConfigFile = (): string => join(oracleDir(), "oracle-triggers.json");

/** The env kill switch: truthy-by-default, off for 0/false/no/off (any case). */
export function triggersDisabledByEnv(env: NodeJS.ProcessEnv = process.env): boolean {
  const raw = env.JUANCODE_TRIGGERS;
  if (raw === undefined) return false;
  return ["0", "false", "no", "off", ""].includes(raw.trim().toLowerCase());
}

function asRecord(v: unknown): Record<string, unknown> | undefined {
  return typeof v === "object" && v !== null && !Array.isArray(v)
    ? (v as Record<string, unknown>)
    : undefined;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.trim() ? v.trim() : undefined;
}

function provider(v: unknown): TriggerProvider | undefined {
  return v === "claude" || v === "codex" || v === "opencode" ? v : undefined;
}

function chatId(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

/**
 * Validate a parsed config object into a usable `TriggerConfig`. Never throws:
 * anything unusable is dropped and explained in `problems`, so one broken
 * schedule can't stop the others (and can't be mistaken for a working one).
 */
export function normalizeTriggerConfig(raw: unknown): TriggerConfig {
  const problems: string[] = [];
  const body = asRecord(raw);
  if (!body) {
    return {
      ...EMPTY_TRIGGER_CONFIG,
      problems: raw === undefined ? [] : ["config is not a JSON object"],
    };
  }

  const allowedProjects: string[] = [];
  const allowedRaw = Array.isArray(body.allowedProjects) ? body.allowedProjects : [];
  for (const entry of allowedRaw) {
    const p = str(entry);
    if (!p) continue;
    if (!isAbsolute(p)) {
      problems.push(`allowedProjects entry "${p}" is not an absolute path — ignored`);
      continue;
    }
    allowedProjects.push(resolve(p));
  }
  if (Array.isArray(body.allowedProjects) && allowedProjects.length === 0) {
    problems.push("allowedProjects is empty — no trigger can fire");
  }

  const repos: Record<string, string> = {};
  for (const [name, value] of Object.entries(asRecord(body.repos) ?? {})) {
    const p = str(value);
    if (!p || !isAbsolute(p)) {
      problems.push(`repos["${name}"] must be an absolute path — ignored`);
      continue;
    }
    repos[name.toLowerCase()] = resolve(p);
  }

  const schedules: ScheduleConfig[] = [];
  const seen = new Set<string>();
  for (const entry of Array.isArray(body.schedules) ? body.schedules : []) {
    const s = asRecord(entry);
    const id = str(s?.id);
    const cron = str(s?.cron);
    const project = str(s?.project);
    const prompt = str(s?.prompt);
    const ticket = str(s?.ticket);
    if (!id) {
      problems.push("a schedule is missing `id` — ignored");
      continue;
    }
    if (seen.has(id)) {
      problems.push(`duplicate schedule id "${id}" — later one ignored`);
      continue;
    }
    if (!cron) {
      problems.push(`schedule "${id}" is missing \`cron\` — ignored`);
      continue;
    }
    const cronProblem = cronError(cron);
    if (cronProblem) {
      problems.push(`schedule "${id}" has a bad cron "${cron}": ${cronProblem} — ignored`);
      continue;
    }
    if (!project || !isAbsolute(project)) {
      problems.push(`schedule "${id}" needs an absolute \`project\` path — ignored`);
      continue;
    }
    if (!prompt && !ticket) {
      problems.push(`schedule "${id}" needs a \`prompt\` or a \`ticket\` — ignored`);
      continue;
    }
    seen.add(id);
    schedules.push({
      id,
      cron,
      project: resolve(project),
      prompt,
      ticket,
      provider: provider(s?.provider),
      worktree: s?.worktree === undefined ? true : s.worktree === true,
      enabled: s?.enabled !== false,
      telegramChatId: chatId(s?.telegramChatId),
    });
  }

  const labels: LabelRuleConfig[] = [];
  for (const entry of Array.isArray(body.labels) ? body.labels : []) {
    const l = asRecord(entry);
    const repo = str(l?.repo);
    const label = str(l?.label);
    if (!repo || !label) {
      problems.push("a label rule needs both `repo` and `label` — ignored");
      continue;
    }
    const project = str(l?.project);
    if (project && !isAbsolute(project)) {
      problems.push(`label rule ${repo}#${label} has a non-absolute \`project\` — ignored`);
      continue;
    }
    labels.push({
      repo,
      label,
      project: project ? resolve(project) : undefined,
      prompt: str(l?.prompt),
      provider: provider(l?.provider),
      worktree: l?.worktree === undefined ? true : l.worktree === true,
      enabled: l?.enabled !== false,
      telegramChatId: chatId(l?.telegramChatId),
    });
  }

  return {
    enabled: body.enabled !== false,
    allowedProjects,
    repos,
    schedules,
    labels,
    problems,
  };
}

/** Read + normalize the trigger config. A missing or unparseable file yields an
 *  empty (nothing-fires) config rather than an exception. */
export async function readTriggerConfig(
  file: string = triggerConfigFile(),
): Promise<TriggerConfig> {
  const raw = await readFile(file, "utf8").catch(() => "");
  if (!raw.trim()) return { ...EMPTY_TRIGGER_CONFIG, allowedProjects: [], problems: [] };
  try {
    return normalizeTriggerConfig(JSON.parse(raw));
  } catch (e) {
    return {
      ...EMPTY_TRIGGER_CONFIG,
      problems: [`${file} is not valid JSON: ${e instanceof Error ? e.message : String(e)}`],
    };
  }
}

/**
 * Is `project` inside the allow list? Compared after `path.resolve`, so `..`
 * segments can't walk out of an allowed root, and a repo is allowed either
 * exactly or as a descendant of an allowed directory. Empty list ⇒ false.
 */
export function projectAllowed(project: string, allowedProjects: string[]): boolean {
  if (!project || !isAbsolute(project)) return false;
  const target = resolve(project);
  return allowedProjects.some((allowed) => {
    const root = resolve(allowed);
    return target === root || target.startsWith(root.endsWith(sep) ? root : root + sep);
  });
}

/** Why a trigger did or didn't dispatch. Always resolved, never thrown. */
export type TriggerResult =
  | { fired: true; outcome: DispatchOutcome }
  | { fired: false; reason: string };

export interface FireTriggerDeps {
  /** Injected so tests never open a WS. Defaults to the real `dispatch()`. */
  dispatch?: (req: DispatchRequest) => Promise<DispatchOutcome>;
  env?: NodeJS.ProcessEnv;
}

/**
 * The single guarded entry point every trigger goes through: kill switch, then
 * allow list, then the ordinary dispatch path. A rejected dispatch comes back as
 * `{fired:false}` with the server's message — a trigger must never throw into a
 * cron tick or a webhook handler.
 */
export async function fireTrigger(
  req: DispatchRequest,
  origin: TriggerOrigin,
  config: TriggerConfig,
  deps: FireTriggerDeps = {},
): Promise<TriggerResult> {
  if (triggersDisabledByEnv(deps.env)) {
    return { fired: false, reason: "triggers are disabled by JUANCODE_TRIGGERS" };
  }
  if (!config.enabled) {
    return { fired: false, reason: "triggers are disabled in oracle-triggers.json" };
  }
  if (!projectAllowed(req.project, config.allowedProjects)) {
    return {
      fired: false,
      reason: `${req.project} is not on the trigger allow list (allowedProjects in oracle-triggers.json)`,
    };
  }
  const run = deps.dispatch ?? dispatch;
  try {
    const outcome = await run({ ...req, trigger: origin });
    return { fired: true, outcome };
  } catch (e) {
    return { fired: false, reason: e instanceof Error ? e.message : String(e) };
  }
}

// ── Seed prompts ─────────────────────────────────────────────────────────────

/** The seed prompt for a ticket-driven schedule. Self-contained: the dispatched
 *  session has fresh context, so it has to be told to read the ticket itself
 *  (`bd show`, stdio-redirected — bd's cold start stalls inherited pipes). */
export function ticketPrompt(ticket: string, scheduleId: string): string {
  return [
    `You were started automatically by the juancode trigger schedule "${scheduleId}".`,
    ``,
    `Work bd ticket ${ticket} end-to-end on this repo: read it, implement it, test it,`,
    `commit, push, close it.`,
    ``,
    `Start with:`,
    ``,
    `    sh -c 'bd show ${ticket} 2>&1 </dev/null'`,
    ``,
    `If the ticket is already closed, or already landed on origin/main, stop and say so`,
    `rather than redoing it. Otherwise claim it`,
    `(\`sh -c 'bd update ${ticket} --status in_progress --json >/dev/null 2>&1 </dev/null'\`),`,
    `follow the repo's CLAUDE.md conventions, run its quality gates before committing, and`,
    `land the work — nobody is watching this session, so do not stop to ask permission.`,
  ].join("\n");
}

/** Fill a rule's prompt template, or build the default label prompt. */
export function labelPrompt(rule: LabelRuleConfig, ev: LabelEvent): string {
  const vars: Record<string, string> = {
    repo: ev.repo,
    number: String(ev.number),
    title: ev.title,
    branch: ev.branch ?? "",
    url: ev.url,
    label: ev.label,
  };
  if (rule.prompt) {
    return rule.prompt.replace(
      /\{(repo|number|title|branch|url|label)\}/g,
      (_m, k: string) => vars[k] ?? "",
    );
  }
  const what = ev.isPr ? "pull request" : "issue";
  const lines = [
    `You were started automatically: the label "${ev.label}" was added to ${ev.repo} ${what} #${ev.number}.`,
    ``,
    `Title: ${ev.title}`,
    `Link: ${ev.url}`,
  ];
  if (ev.branch) {
    lines.push(
      `Branch: ${ev.branch}`,
      ``,
      // The create wire message has no branch field, so the worktree lands on the
      // default branch and the agent moves it — see the note on labelDispatchRequest.
      `You are in a fresh git worktree off the repo. Check that branch out here first`,
      `(\`git fetch origin ${ev.branch} && git checkout ${ev.branch}\`) before changing anything.`,
    );
  } else {
    lines.push(``, `You are in a fresh git worktree off the repo's default branch.`);
  }
  lines.push(
    ``,
    `Read the ${what} with \`gh ${ev.isPr ? "pr" : "issue"} view ${ev.number} --repo ${ev.repo}\`,`,
    `do what it asks, follow the repo's CLAUDE.md conventions, and run its quality gates.`,
    `Nobody is watching this session, so do not stop to ask permission; if the request is`,
    `ambiguous or unsafe, say what you would need and stop rather than guessing.`,
  );
  return lines.join("\n");
}

// ── Label rules ──────────────────────────────────────────────────────────────

/** A "gained a label" webhook event, reduced to what a trigger needs. */
export interface LabelEvent {
  /** GitHub `owner/name`. */
  repo: string;
  label: string;
  number: number;
  title: string;
  /** The PR's head branch; null for a plain issue. */
  branch: string | null;
  url: string;
  isPr: boolean;
}

export interface LabelMatch {
  rule: LabelRuleConfig;
  /** The resolved local repo path (rule.project, else the `repos` map). */
  project: string;
}

/** The first enabled rule matching this event, with its repo path resolved.
 *  Returns null when nothing matches or the repo has no local path configured. */
export function matchLabelRule(config: TriggerConfig, ev: LabelEvent): LabelMatch | null {
  const repoKey = ev.repo.toLowerCase();
  const label = ev.label.toLowerCase();
  for (const rule of config.labels) {
    if (rule.enabled === false) continue;
    if (rule.repo.toLowerCase() !== repoKey) continue;
    if (rule.label.toLowerCase() !== label) continue;
    const project = rule.project ?? config.repos[repoKey];
    if (!project) continue;
    return { rule, project };
  }
  return null;
}

/**
 * Turn a matched label rule into a dispatch request + origin tag.
 *
 * `worktree: true` gives the agent an isolated checkout, but the native `create`
 * message has no branch field (that lives in apps/native's WireProtocol), so the
 * worktree starts on the repo's default branch and the prompt tells the agent to
 * check the PR branch out itself. A `branch` on the create is the follow-up.
 */
export function labelDispatchRequest(
  match: LabelMatch,
  ev: LabelEvent,
): {
  request: DispatchRequest;
  origin: TriggerOrigin;
} {
  return {
    request: {
      project: match.project,
      prompt: labelPrompt(match.rule, ev),
      provider: match.rule.provider ?? "claude",
      worktree: match.rule.worktree !== false,
      telegramChatId: match.rule.telegramChatId ?? null,
    },
    origin: {
      kind: "label",
      id: `${match.rule.repo}#${match.rule.label}`,
      detail: `label "${ev.label}" on ${ev.repo}#${ev.number}`,
    },
  };
}

/**
 * Handle one label webhook event end-to-end: read the config, match a rule, fire.
 * Logs its decision (including every refusal) and never throws — the webhook route
 * calls this fire-and-forget.
 */
export async function handleLabelEvent(
  ev: LabelEvent,
  deps: FireTriggerDeps & { readConfig?: () => Promise<TriggerConfig> } = {},
): Promise<TriggerResult> {
  const config = await (deps.readConfig ?? readTriggerConfig)();
  const match = matchLabelRule(config, ev);
  if (!match) {
    return { fired: false, reason: `no trigger rule for label "${ev.label}" on ${ev.repo}` };
  }
  const { request, origin } = labelDispatchRequest(match, ev);
  const result = await fireTrigger(request, origin, config, deps);
  if (result.fired) {
    console.log(`trigger: ${origin.detail} → ${result.outcome.message}`);
  } else {
    console.warn(`trigger: ${origin.detail} did not dispatch: ${result.reason}`);
  }
  return result;
}
