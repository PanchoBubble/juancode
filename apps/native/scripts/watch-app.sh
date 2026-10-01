#!/usr/bin/env bash
# Watch apps/native and relaunch the app on every successful build. `pnpm dev:app`.
#
# The loop itself is scripts/watch-app.mjs; this wrapper exists for the teardown. The
# trap sends TERM to this whole process group on every exit path, so a Ctrl-C, a closed
# terminal or a crash of the watcher leaves no build and no app behind. The daemon is
# not in this group (launchd or another shell started it), so it is never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# The watcher goes first so it can quit the app it launched by pid and wait for it;
# `kill 0` then sweeps whatever is left in the group (a swift build mid-compile). TERM
# is ignored here only so the sweep cannot cut this handler short.
NODE_PID=""
cleanup() {
  trap - EXIT INT TERM HUP
  if [ -n "$NODE_PID" ]; then
    kill -TERM "$NODE_PID" 2>/dev/null || true
    wait "$NODE_PID" 2>/dev/null || true
  fi
  trap '' TERM
  kill 0 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

node "$ROOT/scripts/watch-app.mjs" "$@" &
NODE_PID=$!
rc=0
wait "$NODE_PID" || rc=$?
NODE_PID=""
exit "$rc"
