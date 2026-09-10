#!/usr/bin/env bash
# The Rust core's daemon, from the repo root.
#
# This is a forwarder, not an implementation. Everything about the daemon's lifetime —
# building it, owning it, refusing to adopt somebody else's, the launchd agent — lives
# in apps/native/scripts/juancoded.sh and juancoded-agent.sh, beside the app that talks
# to it. This file exists because it is where people (and `grep juancoded scripts/`)
# look, and because juancode-k0bq was, in part, exactly that: nothing under scripts/ or
# in package.json mentioned the daemon, so the answer to "how do I start the Rust core"
# was "read CoreBackendViews.swift and run cargo by hand".
#
#   scripts/dev-daemon.sh status         # what is running, who owns it, is it stale
#   scripts/dev-daemon.sh restart        # onto the current build (ends its ptys, asks)
#   scripts/dev-daemon.sh stop           # end it (asks)
#   scripts/dev-daemon.sh agent install  # keep it running across logins
#   scripts/dev-daemon.sh agent status   # …and everything else in juancoded-agent.sh
#
# Also reachable as `pnpm daemon`, `pnpm daemon:agent` (see package.json).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${1:-}" = "agent" ]; then
  shift
  exec "$ROOT/apps/native/scripts/juancoded-agent.sh" "$@"
fi

exec "$ROOT/apps/native/scripts/juancoded.sh" "$@"
