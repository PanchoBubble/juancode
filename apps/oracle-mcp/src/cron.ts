// A minute-resolution cron matcher, just enough for the trigger schedules
// (juancode-chhr) and no dependency to keep current. Five standard fields:
//
//   minute hour day-of-month month day-of-week
//
// Each field takes `*`, a number, a `a-b` range, a comma list of either, and a
// `/step` suffix on any of those (`*/15`, `9-17/2`). Day-of-week accepts 0-7 with
// both 0 and 7 meaning Sunday, and three-letter names (mon, tue, …); month accepts
// 1-12 and names (jan, feb, …).
//
// The one non-obvious rule is real cron's: when BOTH day-of-month and day-of-week
// are restricted, a date matches if EITHER matches (so `0 3 1 * mon` fires on the
// 1st and on every Monday). When only one is restricted it must match.
//
// Matching is against the host's local time — a schedule written as "0 3 * * *"
// means 3am where the Mac is, which is what a human editing the file expects.

export interface CronFields {
  minute: Set<number>;
  hour: Set<number>;
  dayOfMonth: Set<number>;
  month: Set<number>;
  dayOfWeek: Set<number>;
  /** Whether the field was something other than `*` — decides the OR rule above. */
  domRestricted: boolean;
  dowRestricted: boolean;
}

const MONTH_NAMES = [
  "jan",
  "feb",
  "mar",
  "apr",
  "may",
  "jun",
  "jul",
  "aug",
  "sep",
  "oct",
  "nov",
  "dec",
];
const DAY_NAMES = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

function namedValue(token: string, names: string[]): number | null {
  const i = names.indexOf(token.toLowerCase());
  return i === -1 ? null : i;
}

/** Expand one field into the set of values it matches. Throws on anything unparseable. */
function parseField(
  raw: string,
  min: number,
  max: number,
  names: string[] = [],
  nameOffset = 0,
): { values: Set<number>; restricted: boolean } {
  const field = raw.trim();
  if (!field) throw new Error("empty cron field");
  const values = new Set<number>();
  let restricted = false;

  for (const part of field.split(",")) {
    const [spec, stepRaw, ...rest] = part.split("/");
    if (rest.length > 0) throw new Error(`bad cron step in "${part}"`);
    let step = 1;
    if (stepRaw !== undefined) {
      step = Number(stepRaw);
      if (!Number.isInteger(step) || step < 1) throw new Error(`bad cron step in "${part}"`);
      restricted = true;
    }

    const one = (token: string): number => {
      const named = namedValue(token, names);
      const n = named !== null ? named + nameOffset : Number(token);
      if (!Number.isInteger(n) || n < min || n > max) {
        throw new Error(`cron value "${token}" out of range ${min}-${max}`);
      }
      return n;
    };

    let lo: number;
    let hi: number;
    const bounds = (spec ?? "").trim();
    if (bounds === "*") {
      lo = min;
      hi = max;
    } else if (bounds.includes("-")) {
      const [a, b, ...extra] = bounds.split("-");
      if (extra.length > 0 || a === undefined || b === undefined) {
        throw new Error(`bad cron range "${bounds}"`);
      }
      lo = one(a);
      hi = one(b);
      if (hi < lo) throw new Error(`descending cron range "${bounds}"`);
      restricted = true;
    } else {
      lo = one(bounds);
      hi = lo;
      restricted = true;
    }
    for (let v = lo; v <= hi; v += step) values.add(v);
  }

  if (values.size === 0) throw new Error(`cron field "${field}" matches nothing`);
  return { values, restricted };
}

/** Parse a 5-field cron expression. Throws with a human-readable reason. */
export function parseCron(expr: string): CronFields {
  const parts = expr.trim().split(/\s+/);
  if (parts.length !== 5) {
    throw new Error(`cron needs 5 fields (minute hour day month weekday), got ${parts.length}`);
  }
  const [m, h, dom, mon, dow] = parts as [string, string, string, string, string];
  const minute = parseField(m, 0, 59);
  const hour = parseField(h, 0, 23);
  const dayOfMonth = parseField(dom, 1, 31);
  const month = parseField(mon, 1, 12, MONTH_NAMES, 1);
  const dayOfWeek = parseField(dow, 0, 7, DAY_NAMES, 0);
  // 7 and 0 are both Sunday; normalise so matching only has to look at 0.
  if (dayOfWeek.values.delete(7)) dayOfWeek.values.add(0);
  return {
    minute: minute.values,
    hour: hour.values,
    dayOfMonth: dayOfMonth.values,
    month: month.values,
    dayOfWeek: dayOfWeek.values,
    domRestricted: dayOfMonth.restricted,
    dowRestricted: dayOfWeek.restricted,
  };
}

/** Does `at` (local time) fall in the minute this expression selects? */
export function cronMatches(fields: CronFields, at: Date): boolean {
  if (!fields.minute.has(at.getMinutes())) return false;
  if (!fields.hour.has(at.getHours())) return false;
  if (!fields.month.has(at.getMonth() + 1)) return false;
  const domHit = fields.dayOfMonth.has(at.getDate());
  const dowHit = fields.dayOfWeek.has(at.getDay());
  if (fields.domRestricted && fields.dowRestricted) return domHit || dowHit;
  return domHit && dowHit;
}

/** Validate an expression without keeping the parse. Returns the failure reason. */
export function cronError(expr: string): string | null {
  try {
    parseCron(expr);
    return null;
  } catch (e) {
    return e instanceof Error ? e.message : String(e);
  }
}
