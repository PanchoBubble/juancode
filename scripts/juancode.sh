#!/usr/bin/env bash
# One entry point for running juancode day to day: the app on the Rust core, with a
# daemon that outlives the app so a relaunch never costs a session.
#
#   scripts/juancode.sh start           # app in the foreground; starts a persistent daemon if none
#   scripts/juancode.sh restart         # upgrade the daemon in place (sessions kept), relaunch the app
#   scripts/juancode.sh restart --hard  # stop the daemon too (asks; ENDS sessions), then start
#   scripts/juancode.sh watch           # `start`, but rebuild + relaunch the app on every save
#   scripts/juancode.sh stop [--all]    # quit the app and the oracle sidecar; --all also the daemon
#   scripts/juancode.sh status          # what daemon is running and whether it matches the checkout
#
# Also `pnpm jc <cmd>`. The shell functions in ~/.zshrc are thin wrappers over this.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$ROOT/apps/native/scripts"
DAEMON="$NATIVE/juancoded.sh"

export JUANCODE_CORE=rust
export JUANCODED_PORT="${JUANCODED_PORT:-4290}"
export JUANCODE_CONFIG="${JUANCODE_CONFIG:-release}"
export JUANCODE_DAEMON_PERSIST=1

say() { printf 'juancode: %s\n' "$*" >&2; }

app_pids() { pgrep -a -f 'juancode.app/Contents/MacOS/juancode' 2>/dev/null || true; }
oracle_pids() {
  {
    pgrep -a -f 'oracle-mcp/node_modules/.*tsx.*src/index.ts' 2>/dev/null
    lsof -ti tcp:4281 -sTCP:LISTEN 2>/dev/null
  } | sort -un
}

# Waits for the pids to exit, escalating to KILL after 10s, so a relaunch never races
# the old instance for :4280.
stop_pids() {
  local what="$1" pids="$2" i
  [ -z "$pids" ] && return 0
  say "stopping $what: $(echo $pids)"
  kill $pids 2>/dev/null || true
  for i in $(seq 1 40); do
    kill -0 $pids 2>/dev/null || return 0
    sleep 0.25
  done
  say "$what did not exit on TERM, killing"
  kill -9 $pids 2>/dev/null || true
}

stop_app() { stop_pids app "$(app_pids)"; }
stop_oracle() { stop_pids "oracle sidecar" "$(oracle_pids)"; }

# The sidecar runs `tsx` without watch, so every launch restarts it to serve current code.
start_oracle() {
  stop_oracle
  (cd "$ROOT/apps/oracle-mcp" &&
    nohup pnpm start >"${TMPDIR:-/tmp}/juancode-oracle-mcp.log" 2>&1 </dev/null &)
  say "oracle sidecar started (log: ${TMPDIR:-/tmp}/juancode-oracle-mcp.log)"
}

daemon_up() { curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$JUANCODED_PORT/health"; }

cmd_start() {
  start_oracle
  exec "$NATIVE/dev-app.sh" "$@"
}

cmd_watch() {
  # The watcher never starts a daemon, so make sure a persistent one is up first.
  daemon_up || "$DAEMON" persist >/dev/null
  start_oracle
  exec "$NATIVE/watch-app.sh" "$@"
}

cmd_restart() {
  local hard=0
  [ "${1:-}" = "--hard" ] && { hard=1; shift; }
  if [ "$hard" = 1 ]; then
    stop_app
    "$DAEMON" stop
  elif daemon_up; then
    if ! "$DAEMON" upgrade; then
      say "the daemon could not be upgraded in place; nothing was restarted."
      say "\`scripts/juancode.sh restart --hard\` replaces it (asks first, ends its sessions)."
      exit 1
    fi
    stop_app
  else
    stop_app
  fi
  cmd_start "$@"
}

cmd_stop() {
  stop_app
  stop_oracle
  [ "${1:-}" = "--all" ] && "$DAEMON" stop
  return 0
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  restart) shift; cmd_restart "$@" ;;
  watch) shift; cmd_watch "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  status) exec "$DAEMON" status ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
