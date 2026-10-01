// Debounce + coalesce for a watch loop whose job is slow (a Swift build).
//
// A burst of saves becomes one run once it has been quiet for `debounceMs`. A save that
// lands while a run is in flight never starts a second concurrent run: it marks the
// scheduler dirty, and exactly one follow-up run is debounced after the current one
// ends, however many saves arrived meanwhile.

import { clearTimeout, setTimeout } from "node:timers";

export function createRebuildScheduler({
  debounceMs,
  run,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
}) {
  let timer = null;
  let running = false;
  let dirty = false;
  let stopped = false;

  function fire() {
    timer = null;
    if (stopped) return;
    running = true;
    dirty = false;
    let done;
    try {
      done = Promise.resolve(run());
    } catch (err) {
      done = Promise.reject(err);
    }
    done
      .catch(() => {})
      .finally(() => {
        running = false;
        if (dirty && !stopped) {
          dirty = false;
          notify();
        }
      });
  }

  function notify() {
    if (stopped) return;
    if (running) {
      dirty = true;
      return;
    }
    if (timer !== null) clearTimer(timer);
    timer = setTimer(fire, debounceMs);
  }

  function stop() {
    stopped = true;
    if (timer !== null) clearTimer(timer);
    timer = null;
  }

  return {
    notify,
    stop,
    get running() {
      return running;
    },
    get pending() {
      return timer !== null || dirty;
    },
  };
}

// The compiler lines worth showing when a build fails: swift prints each diagnostic with
// its source context, and the context is what turns 3 errors into 60 lines.
export function summarizeBuildErrors(output, max = 15) {
  const lines = output.split("\n").map((l) => l.trimEnd());
  const seen = new Set();
  const errors = [];
  for (const line of lines) {
    if (!/(^|\s)error:/.test(line) || seen.has(line)) continue;
    seen.add(line);
    errors.push(line);
  }
  if (errors.length === 0) return lines.filter(Boolean).slice(-20);
  if (errors.length <= max) return errors;
  return [...errors.slice(0, max), `… and ${errors.length - max} more error line(s)`];
}

// Editor droppings (vim swap files, `.DS_Store`, backup files) and build output are not
// source changes; rebuilding for them is how a watch loop ends up rebuilding forever.
export function isSourceChange(relPath) {
  if (!relPath) return true;
  const parts = relPath.split(/[\\/]/);
  const base = parts[parts.length - 1];
  if (parts.some((p) => p === ".build" || p === ".swiftpm")) return false;
  if (base.startsWith(".") || base.endsWith("~")) return false;
  if (/\.(swp|swx|tmp)$/.test(base) || /^\d+$/.test(base)) return false;
  return true;
}
