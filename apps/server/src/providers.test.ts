import { describe, expect, it } from "vitest";
import { PROVIDERS } from "./providers.ts";

describe("provider startArgs", () => {
  const id = "11111111-1111-1111-1111-111111111111";

  it("passes no accept-all flag by default", () => {
    // Bypass is strictly opt-in: a default session launches exactly as before, so
    // normal permission prompts (and plain resume) keep working.
    expect(PROVIDERS.claude.startArgs(id)).toEqual(["--session-id", id]);
    expect(PROVIDERS.codex.startArgs(id)).toEqual([]);
  });

  it("activates the per-provider accept-all flag when skipPermissions is set", () => {
    expect(PROVIDERS.claude.startArgs(id, { skipPermissions: true })).toEqual([
      "--session-id",
      id,
      "--dangerously-skip-permissions",
    ]);
    expect(PROVIDERS.codex.startArgs(id, { skipPermissions: true })).toEqual([
      "--dangerously-bypass-approvals-and-sandbox",
    ]);
  });
});

describe("provider resumeArgs", () => {
  const sid = "abc-123";

  it("resumes with no accept-all flag by default", () => {
    expect(PROVIDERS.claude.resumeArgs(sid)).toEqual(["--resume", sid]);
    expect(PROVIDERS.codex.resumeArgs(sid)).toEqual(["resume", sid]);
  });

  it("resumes with the accept-all flag when skipPermissions is set", () => {
    expect(PROVIDERS.claude.resumeArgs(sid, { skipPermissions: true })).toEqual([
      "--resume",
      sid,
      "--dangerously-skip-permissions",
    ]);
    expect(PROVIDERS.codex.resumeArgs(sid, { skipPermissions: true })).toEqual([
      "resume",
      "--dangerously-bypass-approvals-and-sandbox",
      sid,
    ]);
  });
});
