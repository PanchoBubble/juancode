import { describe, expect, it } from "vitest";
import type { DispatchRecord } from "./dispatch-registry.ts";
import type { DispatchStatus } from "./dispatch-status.ts";
import {
  DUPLICATE_WINDOW_MS,
  QUEUED_PENDING_WINDOW_MS,
  findDuplicate,
  findTicketConflict,
  liveDispatches,
  recordFingerprint,
  recordTickets,
  requestFingerprint,
  ticketIdsInPrompt,
} from "./dispatch-guard.ts";

// The two keys that stop one piece of work becoming two agent sessions: the
// request fingerprint (a blind retry) and the bd ticket id (the same work, worded
// differently). Both are only useful if they're tight — a guard that refuses
// ordinary dispatches gets forced past and stops guarding anything.

const NOW = 1_700_000_000_000;

function record(over: Partial<DispatchRecord> = {}): DispatchRecord {
  return {
    dispatchId: "d-1",
    project: "/repo",
    prompt: "do the thing",
    provider: "claude",
    worktree: true,
    telegramChatId: null,
    outcome: "started",
    sessionId: "s-1",
    error: null,
    at: NOW,
    ...over,
  };
}

function status(over: Partial<DispatchStatus> & { request: DispatchRecord }): DispatchStatus {
  return {
    dispatchId: over.request.dispatchId,
    result: null,
    session: null,
    ...over,
  };
}

const runningSession = (id: string) => ({
  id,
  title: "",
  cwd: "/repo",
  provider: "claude",
  status: "running",
  dispatchId: null,
});

describe("ticketIdsInPrompt", () => {
  it("reads the ticket out of the phrasings the dispatch skills actually emit", () => {
    expect(ticketIdsInPrompt("Implement bd ticket juancode-nwrb end-to-end.")).toEqual([
      "juancode-nwrb",
    ]);
    expect(ticketIdsInPrompt("Work bd ticket juancode-2kz.1 end-to-end on this repo.")).toEqual([
      "juancode-2kz.1",
    ]);
    expect(ticketIdsInPrompt("Start with: sh -c 'bd show juancode-h1an 2>&1 </dev/null'")).toEqual([
      "juancode-h1an",
    ]);
    // bd's own header line, with and without the status glyph.
    expect(ticketIdsInPrompt("◐ juancode-nwrb [BUG] · Dispatch can send the same ticket")).toEqual([
      "juancode-nwrb",
    ]);
    expect(ticketIdsInPrompt("juancode-abc9 [TASK] · something")).toEqual(["juancode-abc9"]);
  });

  it("ignores hyphenated words that merely look bd-shaped", () => {
    expect(
      ticketIdsInPrompt(
        "Use claude-code and the worktree-sweeper agent; apps/native is the surface. " +
          "Do not run cargo fmt --all. See juancode-nqpm (delete the Swift core) for context.",
      ),
    ).toEqual([]);
  });

  it("does not let a leading glyph eat the id's first letter", () => {
    // `\S?` for the bullet used to match the "j" and report "uancode-nwrb".
    expect(ticketIdsInPrompt("juancode-nwrb [BUG] x")).toEqual(["juancode-nwrb"]);
  });

  it("collects every ticket the prompt names, lowercased and deduped", () => {
    const ids = ticketIdsInPrompt(
      "Implement bd ticket JUANCODE-NWRB. Also run bd show juancode-nwrb and ticket juancode-h1an.",
    );
    expect(ids).toEqual(["juancode-nwrb", "juancode-h1an"]);
  });
});

describe("requestFingerprint", () => {
  it("is stable for the same request and differs on every dispatched field", () => {
    const base = { project: "/repo", prompt: "p", provider: "claude", worktree: true };
    expect(requestFingerprint(base)).toBe(requestFingerprint({ ...base }));
    expect(requestFingerprint({ ...base, project: "/other" })).not.toBe(requestFingerprint(base));
    expect(requestFingerprint({ ...base, prompt: "p " })).not.toBe(requestFingerprint(base));
    expect(requestFingerprint({ ...base, provider: "codex" })).not.toBe(requestFingerprint(base));
    expect(requestFingerprint({ ...base, worktree: false })).not.toBe(requestFingerprint(base));
  });

  it("lets a caller-supplied key replace the content hash", () => {
    const a = requestFingerprint({ project: "/repo", prompt: "one", idempotencyKey: "k" });
    const b = requestFingerprint({ project: "/repo", prompt: "two", idempotencyKey: "k" });
    expect(a).toBe(b);
    expect(a).toBe("key:k");
  });

  it("recomputes a record's fingerprint when it predates the field", () => {
    const r = record({ prompt: "p" });
    expect(recordFingerprint(r)).toBe(
      requestFingerprint({ project: "/repo", prompt: "p", provider: "claude", worktree: true }),
    );
    expect(recordFingerprint(record({ fingerprint: "key:explicit" }))).toBe("key:explicit");
  });

  it("falls back to the stored prompt for a record's tickets", () => {
    expect(recordTickets(record({ prompt: "Implement bd ticket juancode-h1an." }))).toEqual([
      "juancode-h1an",
    ]);
    expect(recordTickets(record({ ticket: "JUANCODE-X1", prompt: "no ids here" }))).toEqual([
      "juancode-x1",
    ]);
  });
});

describe("findDuplicate", () => {
  const fp = requestFingerprint({
    project: "/repo",
    prompt: "do the thing",
    provider: "claude",
    worktree: true,
  });

  it("matches a same-fingerprint dispatch inside the window", () => {
    const hit = findDuplicate([status({ request: record({ at: NOW - 30_000 }) })], fp, NOW);
    expect(hit?.dispatchId).toBe("d-1");
  });

  it("does not match once the window has passed", () => {
    const old = record({ at: NOW - DUPLICATE_WINDOW_MS - 1 });
    expect(findDuplicate([status({ request: old })], fp, NOW)).toBeNull();
  });

  it("ignores a rejected dispatch — re-posting it is the right move", () => {
    const rejected = record({ outcome: "rejected", sessionId: null, error: "bad path" });
    expect(findDuplicate([status({ request: rejected })], fp, NOW)).toBeNull();
  });

  it("matches a queued dispatch — the retry that bit us", () => {
    const queued = record({ outcome: "queued", sessionId: null, at: NOW - 5_000 });
    expect(findDuplicate([status({ request: queued })], fp, NOW)?.outcome).toBe("queued");
  });

  it("returns the newest of several matches", () => {
    const hit = findDuplicate(
      [
        status({ request: record({ dispatchId: "old", at: NOW - 120_000 }) }),
        status({ request: record({ dispatchId: "new", at: NOW - 10_000 }) }),
      ],
      fp,
      NOW,
    );
    expect(hit?.dispatchId).toBe("new");
  });
});

describe("liveDispatches / findTicketConflict", () => {
  const ticketed = (over: Partial<DispatchRecord> = {}) =>
    record({ prompt: "Implement bd ticket juancode-h1an end-to-end.", ...over });

  it("counts a dispatch whose session the app reports as running", () => {
    const live = liveDispatches(
      [status({ request: ticketed(), session: runningSession("s-1") })],
      NOW,
    );
    expect(live).toHaveLength(1);
    expect(live[0]).toMatchObject({ state: "running", sessionId: "s-1" });
    expect(findTicketConflict(live, ["juancode-h1an"])?.dispatchId).toBe("d-1");
  });

  it("counts a queued dispatch that has not resulted yet — it is still coming", () => {
    const live = liveDispatches(
      [status({ request: ticketed({ outcome: "queued", sessionId: null, at: NOW - 60_000 }) })],
      NOW,
    );
    expect(live[0]).toMatchObject({ state: "queued" });
  });

  it("stops counting a queued dispatch once a result landed, or it went stale", () => {
    const resulted = status({
      request: ticketed({ outcome: "queued", sessionId: null }),
      result: {
        dispatchId: "d-1",
        project: "/repo",
        ok: true,
        sessionId: "s-9",
        error: null,
        at: NOW,
      },
    });
    expect(liveDispatches([resulted], NOW)).toEqual([]);

    const stale = status({
      request: ticketed({
        outcome: "queued",
        sessionId: null,
        at: NOW - QUEUED_PENDING_WINDOW_MS - 1,
      }),
    });
    expect(liveDispatches([stale], NOW)).toEqual([]);
  });

  it("does not count a session that has exited", () => {
    const exited = status({
      request: ticketed(),
      session: { ...runningSession("s-1"), status: "exited" },
    });
    expect(liveDispatches([exited], NOW)).toEqual([]);
  });

  it("finds no conflict for a different ticket, or for a prompt naming none", () => {
    const live = liveDispatches(
      [status({ request: ticketed(), session: runningSession("s-1") })],
      NOW,
    );
    expect(findTicketConflict(live, ["juancode-29ci"])).toBeNull();
    expect(findTicketConflict(live, [])).toBeNull();
  });
});
