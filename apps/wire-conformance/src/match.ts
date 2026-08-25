// The matcher the golden transcripts are written in.
//
// A transcript step says what a frame must look like, not what it must be equal
// to: field order, timestamps, uuids and platform-dependent counts are not part
// of the contract, so a literal deep-equal would encode noise as spec. Objects
// match partially (only the listed keys are checked), arrays match positionally
// and by length, and anything looser is spelled with an explicit operator.

export type Vars = Record<string, unknown>;

export interface MatchResult {
  ok: boolean;
  /** Path + reason of the first mismatch, for a readable assertion message. */
  why?: string;
}

const OK: MatchResult = { ok: true };

function fail(path: string, why: string): MatchResult {
  return { ok: false, why: `${path || "<root>"}: ${why}` };
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** Operator keys a matcher object may use. Anything else is a literal field. */
const OPERATORS = new Set([
  "$var",
  "$any",
  "$absent",
  "$present",
  "$type",
  "$oneOf",
  "$regex",
  "$contains",
  "$notContains",
  "$gte",
  "$gt",
  "$lte",
  "$lt",
  "$length",
  "$exact",
  "$not",
  "$every",
  "$some",
]);

/** An all-`$`-keys object is a matcher, even if the key is a typo: a mistyped
 *  operator must be an error, never a silently-passing literal comparison. */
function isOperator(v: unknown): v is Record<string, unknown> {
  if (!isPlainObject(v)) return false;
  const keys = Object.keys(v);
  if (keys.length === 0) return false;
  return keys.some((k) => OPERATORS.has(k)) || keys.every((k) => k.startsWith("$"));
}

function show(v: unknown): string {
  const s = JSON.stringify(v);
  return s === undefined ? String(v) : s.length > 200 ? `${s.slice(0, 200)}…` : s;
}

/** Substitute bound variables into a payload: an exact "$name" string becomes the
 *  bound value; everything else is copied. Used for the client frames a scenario
 *  sends, so a step can address the session a previous step bound. */
export function resolveVars(value: unknown, vars: Vars): unknown {
  if (typeof value === "string" && value.startsWith("$")) {
    const name = value.slice(1);
    if (name in vars) return vars[name];
    return value;
  }
  if (Array.isArray(value)) return value.map((v) => resolveVars(v, vars));
  if (isPlainObject(value)) {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) out[k] = resolveVars(v, vars);
    return out;
  }
  return value;
}

export function matchValue(
  actual: unknown,
  expected: unknown,
  vars: Vars = {},
  path = "",
): MatchResult {
  if (isOperator(expected)) return matchOperator(actual, expected, vars, path);

  if (typeof expected === "string" && expected.startsWith("$") && expected.slice(1) in vars) {
    return matchValue(actual, vars[expected.slice(1)], vars, path);
  }

  if (Array.isArray(expected)) {
    if (!Array.isArray(actual)) return fail(path, `expected an array, got ${show(actual)}`);
    if (actual.length !== expected.length) {
      return fail(path, `expected ${expected.length} items, got ${actual.length}`);
    }
    for (let i = 0; i < expected.length; i++) {
      const r = matchValue(actual[i], expected[i], vars, `${path}[${i}]`);
      if (!r.ok) return r;
    }
    return OK;
  }

  if (isPlainObject(expected)) {
    if (!isPlainObject(actual)) return fail(path, `expected an object, got ${show(actual)}`);
    for (const [k, v] of Object.entries(expected)) {
      const r = matchValue(actual[k], v, vars, path ? `${path}.${k}` : k);
      if (!r.ok) return r;
    }
    return OK;
  }

  if (actual !== expected) return fail(path, `expected ${show(expected)}, got ${show(actual)}`);
  return OK;
}

function matchOperator(
  actual: unknown,
  op: Record<string, unknown>,
  vars: Vars,
  path: string,
): MatchResult {
  for (const [key, arg] of Object.entries(op)) {
    if (!OPERATORS.has(key)) return fail(path, `unknown matcher operator ${key}`);
    const r = applyOperator(key, arg, actual, vars, path);
    if (!r.ok) return r;
  }
  return OK;
}

function applyOperator(
  key: string,
  arg: unknown,
  actual: unknown,
  vars: Vars,
  path: string,
): MatchResult {
  switch (key) {
    case "$any":
      return OK;
    case "$var": {
      const name = String(arg);
      if (!(name in vars)) return fail(path, `variable $${name} is not bound`);
      return matchValue(actual, vars[name], vars, path);
    }
    case "$absent":
      return actual === undefined
        ? OK
        : fail(path, `expected the key to be absent, got ${show(actual)}`);
    case "$present":
      return actual !== undefined ? OK : fail(path, "expected the key to be present");
    case "$type": {
      const want = String(arg);
      const got = actual === null ? "null" : Array.isArray(actual) ? "array" : typeof actual;
      return got === want ? OK : fail(path, `expected type ${want}, got ${got}`);
    }
    case "$oneOf": {
      const options = arg as unknown[];
      for (const o of options) if (matchValue(actual, o, vars, path).ok) return OK;
      return fail(path, `expected one of ${show(options)}, got ${show(actual)}`);
    }
    case "$regex": {
      if (typeof actual !== "string") return fail(path, `expected a string, got ${show(actual)}`);
      return new RegExp(String(arg)).test(actual)
        ? OK
        : fail(path, `expected to match /${String(arg)}/, got ${show(actual)}`);
    }
    case "$contains": {
      const needle = resolveVars(arg, vars);
      if (typeof actual === "string") {
        return actual.includes(String(needle))
          ? OK
          : fail(path, `expected to contain ${show(needle)}`);
      }
      if (Array.isArray(actual)) {
        return actual.some((v) => matchValue(v, needle, vars, path).ok)
          ? OK
          : fail(path, `expected an item matching ${show(needle)}`);
      }
      return fail(path, `expected a string or array, got ${show(actual)}`);
    }
    case "$notContains": {
      const needle = resolveVars(arg, vars);
      if (typeof actual === "string") {
        return actual.includes(String(needle))
          ? fail(path, `expected NOT to contain ${show(needle)}`)
          : OK;
      }
      if (Array.isArray(actual)) {
        return actual.some((v) => matchValue(v, needle, vars, path).ok)
          ? fail(path, `expected no item matching ${show(needle)}`)
          : OK;
      }
      return fail(path, `expected a string or array, got ${show(actual)}`);
    }
    case "$gte":
    case "$gt":
    case "$lte":
    case "$lt": {
      if (typeof actual !== "number") return fail(path, `expected a number, got ${show(actual)}`);
      // Through resolveVars so a bound value can be the bound: a transcript asserts
      // that a live batch's seq is above the last one a replay carried, and the only
      // place that number exists is a variable a previous step bound.
      const n = Number(resolveVars(arg, vars));
      if (Number.isNaN(n)) return fail(path, `${key} needs a number, got ${show(arg)}`);
      const ok =
        key === "$gte"
          ? actual >= n
          : key === "$gt"
            ? actual > n
            : key === "$lte"
              ? actual <= n
              : actual < n;
      return ok ? OK : fail(path, `expected ${key.slice(1)} ${n}, got ${actual}`);
    }
    case "$length": {
      const len = typeof actual === "string" || Array.isArray(actual) ? actual.length : undefined;
      if (len === undefined) return fail(path, `expected a string or array, got ${show(actual)}`);
      return matchValue(len, arg, vars, `${path}.length`);
    }
    case "$exact": {
      const want = resolveVars(arg, vars);
      return JSON.stringify(actual) === JSON.stringify(want)
        ? OK
        : fail(path, `expected exactly ${show(want)}, got ${show(actual)}`);
    }
    case "$not":
      return matchValue(actual, arg, vars, path).ok
        ? fail(path, `expected NOT to match ${show(arg)}`)
        : OK;
    case "$every": {
      if (!Array.isArray(actual)) return fail(path, `expected an array, got ${show(actual)}`);
      for (let i = 0; i < actual.length; i++) {
        const r = matchValue(actual[i], arg, vars, `${path}[${i}]`);
        if (!r.ok) return r;
      }
      return OK;
    }
    case "$some": {
      if (!Array.isArray(actual)) return fail(path, `expected an array, got ${show(actual)}`);
      for (let i = 0; i < actual.length; i++) {
        if (matchValue(actual[i], arg, vars, `${path}[${i}]`).ok) return OK;
      }
      return fail(path, `expected some item to match ${show(arg)}`);
    }
    default:
      return fail(path, `unhandled operator ${key}`);
  }
}

/** Read the values a step binds out of a matched frame: `{ "session": "session.id" }`
 *  binds the frame's `session.id` under `$session`. */
export function readBindings(frame: Record<string, unknown>, bind: Record<string, string>): Vars {
  const out: Vars = {};
  for (const [name, pointer] of Object.entries(bind)) {
    let cur: unknown = frame;
    for (const part of pointer.split(".")) {
      if (Array.isArray(cur) && /^\d+$/.test(part)) {
        cur = cur[Number(part)];
        continue;
      }
      if (!isPlainObject(cur)) {
        cur = undefined;
        break;
      }
      cur = cur[part];
    }
    out[name] = cur;
  }
  return out;
}
