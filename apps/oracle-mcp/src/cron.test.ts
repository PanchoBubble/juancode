import { describe, expect, it } from "vitest";
import { cronError, cronMatches, parseCron } from "./cron.ts";

/** Local-time date, so the matcher is exercised the way schedules are read. */
const at = (y: number, mo: number, d: number, h: number, mi: number) =>
  new Date(y, mo - 1, d, h, mi, 0, 0);

const matches = (expr: string, date: Date) => cronMatches(parseCron(expr), date);

describe("parseCron", () => {
  it("rejects an expression without 5 fields", () => {
    expect(cronError("* * *")).toMatch(/needs 5 fields/);
    expect(cronError("* * * * * *")).toMatch(/needs 5 fields/);
  });

  it("rejects out-of-range and malformed values", () => {
    expect(cronError("60 * * * *")).toMatch(/out of range/);
    expect(cronError("* 24 * * *")).toMatch(/out of range/);
    expect(cronError("* * 0 * *")).toMatch(/out of range/);
    expect(cronError("*/0 * * * *")).toMatch(/bad cron step/);
    expect(cronError("5-1 * * * *")).toMatch(/descending/);
    expect(cronError("nope * * * *")).toMatch(/out of range/);
  });

  it("accepts the forms the config file uses", () => {
    for (const expr of ["0 3 * * *", "*/15 * * * *", "0 9-17/2 * * mon-fri", "30 2 1 jan *"]) {
      expect(cronError(expr)).toBeNull();
    }
  });

  it("treats weekday 7 as Sunday", () => {
    const fields = parseCron("0 0 * * 7");
    expect(fields.dayOfWeek.has(0)).toBe(true);
    expect(fields.dayOfWeek.has(7)).toBe(false);
  });
});

describe("cronMatches", () => {
  it("matches an exact minute and hour only", () => {
    expect(matches("0 3 * * *", at(2026, 9, 10, 3, 0))).toBe(true);
    expect(matches("0 3 * * *", at(2026, 9, 10, 3, 1))).toBe(false);
    expect(matches("0 3 * * *", at(2026, 9, 10, 4, 0))).toBe(false);
  });

  it("honours a step", () => {
    expect(matches("*/15 * * * *", at(2026, 9, 10, 1, 0))).toBe(true);
    expect(matches("*/15 * * * *", at(2026, 9, 10, 1, 15))).toBe(true);
    expect(matches("*/15 * * * *", at(2026, 9, 10, 1, 16))).toBe(false);
  });

  it("honours a comma list and a range", () => {
    expect(matches("0,30 * * * *", at(2026, 9, 10, 1, 30))).toBe(true);
    expect(matches("0,30 * * * *", at(2026, 9, 10, 1, 29))).toBe(false);
    // 2026-09-10 is a Thursday; 2026-09-12 a Saturday.
    expect(matches("0 9 * * mon-fri", at(2026, 9, 10, 9, 0))).toBe(true);
    expect(matches("0 9 * * mon-fri", at(2026, 9, 12, 9, 0))).toBe(false);
  });

  it("ORs day-of-month with day-of-week when both are restricted", () => {
    // 2026-09-01 is a Tuesday, 2026-09-07 a Monday, 2026-09-08 a Tuesday.
    const expr = "0 3 1 * mon";
    expect(matches(expr, at(2026, 9, 1, 3, 0))).toBe(true); // day-of-month hit
    expect(matches(expr, at(2026, 9, 7, 3, 0))).toBe(true); // day-of-week hit
    expect(matches(expr, at(2026, 9, 8, 3, 0))).toBe(false); // neither
  });

  it("ANDs when only one of the day fields is restricted", () => {
    expect(matches("0 3 10 * *", at(2026, 9, 10, 3, 0))).toBe(true);
    expect(matches("0 3 10 * *", at(2026, 9, 11, 3, 0))).toBe(false);
    expect(matches("0 3 * 9 *", at(2026, 9, 11, 3, 0))).toBe(true);
    expect(matches("0 3 * 9 *", at(2026, 10, 11, 3, 0))).toBe(false);
  });
});
