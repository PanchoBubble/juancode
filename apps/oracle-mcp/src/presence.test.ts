import { afterEach, describe, expect, it } from "vitest";
import { presenceWindowMs, suppressForPresence, type Presence } from "./presence.ts";

describe("suppressForPresence", () => {
  const WINDOW = 60_000;
  const NOW = 1_000_000;

  it("suppresses when the desktop is active", () => {
    const presence: Presence = { active: true, lastActiveMs: null };
    expect(suppressForPresence(presence, WINDOW, NOW)).toBe(true);
  });

  it("suppresses when lastActiveMs is within the window", () => {
    const presence: Presence = { active: false, lastActiveMs: NOW - 30_000 };
    expect(suppressForPresence(presence, WINDOW, NOW)).toBe(true);
  });

  it("suppresses at exactly the window boundary", () => {
    const presence: Presence = { active: false, lastActiveMs: NOW - WINDOW };
    expect(suppressForPresence(presence, WINDOW, NOW)).toBe(true);
  });

  it("does NOT suppress when lastActiveMs is stale (outside the window)", () => {
    const presence: Presence = { active: false, lastActiveMs: NOW - WINDOW - 1 };
    expect(suppressForPresence(presence, WINDOW, NOW)).toBe(false);
  });

  it("does NOT suppress when inactive with no lastActiveMs", () => {
    const presence: Presence = { active: false, lastActiveMs: null };
    expect(suppressForPresence(presence, WINDOW, NOW)).toBe(false);
  });

  it("fails open (does NOT suppress) when presence is unreachable", () => {
    expect(suppressForPresence(null, WINDOW, NOW)).toBe(false);
  });
});

describe("presenceWindowMs", () => {
  const prev = process.env.JUANCODE_PRESENCE_WINDOW_MS;
  afterEach(() => {
    if (prev === undefined) delete process.env.JUANCODE_PRESENCE_WINDOW_MS;
    else process.env.JUANCODE_PRESENCE_WINDOW_MS = prev;
  });

  it("defaults to 60000", () => {
    delete process.env.JUANCODE_PRESENCE_WINDOW_MS;
    expect(presenceWindowMs()).toBe(60_000);
  });

  it("reads a valid override", () => {
    process.env.JUANCODE_PRESENCE_WINDOW_MS = "5000";
    expect(presenceWindowMs()).toBe(5000);
  });

  it("falls back to the default on a non-numeric value", () => {
    process.env.JUANCODE_PRESENCE_WINDOW_MS = "nope";
    expect(presenceWindowMs()).toBe(60_000);
  });
});
