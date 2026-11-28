// Context rotation is owned by the sidecar, so the agent need not spend a tool
// turn watching its own usage or block waiting for its own handoff note.
import { onSessionUsage, sessionActivity, type SessionUsageSample } from "./native-events.ts";
import { defaultHandoffDeps, handOffSession, type HandoffDeps } from "./session-handoff.ts";

/** Leave space for the current turn and the continuation note. Zero disables. */
export function autoHandoffFraction(env: NodeJS.ProcessEnv = process.env): number {
  const raw = env.JUANCODE_AUTO_HANDOFF_PERCENT?.trim();
  const percent = raw ? Number(raw) : 80;
  return Number.isFinite(percent) && percent >= 0 && percent < 100 ? percent / 100 : 0.8;
}

export interface AutoHandoffDeps {
  activity: HandoffDeps["activity"];
  source: HandoffDeps["source"];
  handoff: (id: string) => Promise<unknown>;
  report: (message: string) => void;
}

/** One attempt per source per sidecar lifetime, even on refusal: an unsuccessful
 * request can still be queued, so retrying could inject duplicate instructions.
 * Idle and waiting-input sessions are never started just because they are large.
 */
export class AutoHandoff {
  private attempted = new Set<string>();

  constructor(
    private readonly fraction: number,
    private readonly deps: AutoHandoffDeps,
  ) {}

  async sample(sample: SessionUsageSample): Promise<void> {
    const { sessionId, contextTokens, contextWindow } = sample;
    if (
      this.fraction <= 0 ||
      contextTokens === undefined ||
      contextWindow === undefined ||
      !Number.isFinite(contextTokens) ||
      !Number.isFinite(contextWindow) ||
      contextWindow <= 0 ||
      contextTokens / contextWindow < this.fraction ||
      this.deps.activity(sessionId) !== "busy" ||
      this.attempted.has(sessionId)
    )
      return;

    // Reserve before any await: telemetry can arrive again during the source read.
    this.attempted.add(sessionId);
    try {
      const source = await this.deps.source(sessionId);
      if (
        !source ||
        source.status !== "running" ||
        (source.kind && source.kind !== "agent") ||
        !["claude", "codex"].includes(source.provider)
      )
        return;
      this.deps.report(`Automatic context handoff requested for ${sessionId}`);
      await this.deps.handoff(sessionId);
      this.deps.report(`Automatic context handoff finished for ${sessionId}`);
    } catch (error) {
      this.deps.report(`Automatic context handoff stopped for ${sessionId}: ${String(error)}`);
    }
  }
}

export function startAutoHandoff(): void {
  const fraction = autoHandoffFraction();
  if (fraction === 0) return;
  const controller = new AutoHandoff(fraction, {
    activity: sessionActivity,
    source: defaultHandoffDeps().source,
    handoff: (id) => handOffSession(id),
    report: (message) => console.log(message),
  });
  onSessionUsage((sample) => {
    void controller.sample(sample);
  });
}
