// Local routing: no classifier API call and no changes to the CLI's environment.
export type TaskComplexity = "simple" | "standard" | "complex";
/** Every provider a dispatch can pin: the one list the schemas, validation and
 * pickers share. */
export const DISPATCH_PROVIDERS = [
  "claude",
  "codex",
  "opencode",
  "kimi",
  "antigravity",
  "cursor",
] as const;
export type DispatchProvider = (typeof DISPATCH_PROVIDERS)[number];

export function isDispatchProvider(v: unknown): v is DispatchProvider {
  return (DISPATCH_PROVIDERS as readonly unknown[]).includes(v);
}
export interface ModelSelection {
  provider: DispatchProvider;
  model: string | null;
  complexity: TaskComplexity;
  reason: string;
}

export interface ModelRequest {
  prompt: string;
  provider?: DispatchProvider;
  /** "default" leaves the model to the CLI; omitted/"auto" routes by task. */
  model?: string;
  complexity?: TaskComplexity;
}

const MODELS = {
  claude: { simple: "sonnet", standard: "opus", complex: "opus" },
  codex: { simple: "gpt-6-luna", standard: "gpt-6.1-sol", complex: "gpt-6-astra" },
};

/** The models of the CLIs we don't pin per complexity. Just as opencode — which has
 * so many models a fixed routing table would be wrong — kimi's and antigravity's
 * aliases are opaque and change too fast to pin here, so a dispatch to either runs the
 * CLI's own default unless an explicit model (or a
 * `JUANCODE_DISPATCH_<PROVIDER>_*_MODEL` knob) was given.
 * Everything is configurable through env, so the table's opinion is a starting
 * point, not a mandate. */
function routingModel(provider: DispatchProvider, complexity: TaskComplexity): string | null {
  if (provider === "claude" || provider === "codex") return MODELS[provider][complexity];
  return null;
}

/** Only clearly bounded chores get the small model. Unknown/ticket-only requests
 * stay standard; risky signals take precedence over words like "typo" or "docs".
 * This is a heuristic, not an estimate of actual token usage or task difficulty. */
export function taskComplexity(prompt: string): TaskComplexity {
  if (
    /\b(architect(?:ure)?|redesign|security|authentication|cryptograph\w*|race condition|deadlock|data loss|distributed|migration)\b/i.test(
      prompt,
    )
  ) {
    return "complex";
  }
  if (
    prompt.length <= 600 &&
    !/\b(implement|debug|investigate|refactor|feature|logic|behavior|behaviour)\b/i.test(prompt) &&
    /\b(typos?|spelling|grammar|formatting|broken link|rename|summari[sz]e|changelog)\b/i.test(
      prompt,
    )
  ) {
    return "simple";
  }
  return "standard";
}

export function selectDispatchModel(
  request: ModelRequest,
  env: NodeJS.ProcessEnv = process.env,
): ModelSelection {
  const complexity = request.complexity ?? taskComplexity(request.prompt);
  const explicit = request.model?.trim();
  // A model without a provider retains the historical Claude provider. Model IDs
  // are opaque: never guess a provider by parsing an override.
  const provider =
    request.provider ??
    (explicit && explicit !== "auto" ? "claude" : complexity === "simple" ? "codex" : "claude");
  if (explicit && explicit !== "auto") {
    return {
      provider,
      model: explicit === "default" ? null : explicit,
      complexity,
      reason: explicit === "default" ? "CLI default requested" : "Explicit model override",
    };
  }
  const configured =
    env[`JUANCODE_DISPATCH_${provider.toUpperCase()}_${complexity.toUpperCase()}_MODEL`]?.trim();
  const routed = routingModel(provider, complexity);
  const model = configured === "default" ? null : configured || routed;
  return {
    provider,
    model,
    complexity,
    reason: `${request.complexity ? "Caller-rated" : "Heuristic"} ${complexity} task${configured ? "; configured model" : routed ? "" : "; CLI default (model left to the CLI)"}`,
  };
}
