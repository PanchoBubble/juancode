#!/usr/bin/env bash
# Own the `juancoded` daemon's lifetime, so launching the app cannot leave you
# talking to a core from two hours ago.
#
# THE BUG THIS EXISTS FOR
#
# The daemon is a separate process that outlives the app on purpose: it holds the
# ptys, and an app relaunch must not end somebody's running agents. Nothing owned
# its lifetime, so it drifted to PPID 1 and stayed there. Relaunching the app just
# reconnected to whatever was still listening on 4290 — an older build, with the
# environment IT was started with. The app's session list is a mirror of what that
# daemon reports, so it looked authoritative while being hours stale, and a
# JUANCODE_SESSIONS_PER_PROJECT set on the app's launch line pruned nothing because
# the daemon never saw it.
#
# ADOPT, DON'T RESTART
#
# Restarting the daemon on every app launch would fix staleness by ending every live
# pty, several times a day. That trade is much worse than the bug. So: adopt a daemon
# that provably matches this checkout, and restart only when it provably does not —
# and never silently. A restart prints what it is about to end and asks.
#
# Matching is decided off the run file the daemon writes while it is listening
# (`$data_dir/juancoded.run`, see juancoded-server/src/identity.rs), which carries the
# pid, the build stamp and the environment values that matter. Same data the app gets
# on `serverInfo.daemon`, so the script and the badge can never disagree.
#
# NEVER pkill BY NAME. The oracle sidecar can be pkilled because a stray copy is
# harmless; a `pkill -f juancoded` would also end the daemon belonging to another
# worktree, and that one is holding real ptys. Only the exact pid from the run file
# is ever signalled, and only after it is confirmed.
#
# Usage:
#   juancoded.sh ensure    # build, then adopt or start; the app-launch path
#   juancoded.sh status    # what is running, and whether it matches this checkout
#   juancoded.sh restart   # end it (after confirming) and start a matching one
#   juancoded.sh stop      # end it (after confirming)
#   juancoded.sh build-id  # print the build identity of the checkout, for stamping
#
# Env:
#   JUANCODE_DAEMON=adopt|ask|restart|off   what `ensure` may do (default: ask)
#       adopt   never end a running daemon, warn if it is stale
#       ask     prompt before ending a stale daemon (default)
#       restart end a stale daemon without asking. Ends live ptys. Say it deliberately.
#       off     do nothing at all; you are managing the daemon yourself
#   JUANCODE_SKIP_DAEMON_BUILD=1            skip `cargo build`
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
MANIFEST="$ROOT/apps/juancoded/Cargo.toml"

# Mirrors `juancoded_persistence::db_path()` exactly. Two spellings of the same
# default in two languages is a drift waiting to happen; this one is the copy, and
# the run file's `data_dir` line is what proves they agreed.
DATA_DIR="${JUANCODED_DATA_DIR:-${JUANCODE_DATA_DIR:-$HOME/.juancode/rust-core}}"
RUN_FILE="$DATA_DIR/juancoded.run"
LOG_FILE="$DATA_DIR/juancoded.log"
PORT="${JUANCODED_PORT:-4290}"
BIN="${JUANCODE_JUANCODED_BIN:-$ROOT/apps/juancoded/target/debug/juancoded}"

say()  { printf 'juancoded: %s\n' "$*" >&2; }
warn() { printf 'juancoded: %s\n' "$*" >&2; }

# One field out of the run file. `sed`, not `source`: the file is written by another
# process and must never be executed.
run_get() { [ -f "$RUN_FILE" ] && sed -n "s/^$1=//p" "$RUN_FILE" | head -1 || true; }

# The identity of the build sitting in the checkout right now. A function of the
# BUILD, never of the launch — an id that changed per launch would make every adoption
# look stale and restart the daemon every time, which is the outcome this script is
# written to avoid.
build_id() {
  local sha dirty stamp
  sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
  dirty=""
  git -C "$ROOT" diff --quiet HEAD -- apps/juancoded 2>/dev/null || dirty="-dirty"
  stamp="$(stat -f %m "$BIN" 2>/dev/null || echo 0)"
  printf '%s%s-%s' "$sha" "$dirty" "$stamp"
}

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

healthy() {
  curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1
}

# The ptys a restart would end, as a count and a list. This is the number that has to
# be on screen before anybody types y.
daemon_children() { pgrep -P "$1" 2>/dev/null || true; }

describe_running() {
  local pid="$1" started exe version keep
  started="$(run_get started_at_ms)"; exe="$(run_get exe)"
  version="$(run_get version)"; keep="$(run_get sessions_per_project)"
  local when="unknown"
  [ -n "$started" ] && when="$(date -r "$((started / 1000))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
  printf '  pid %s, v%s, up since %s\n' "$pid" "${version:-?}" "$when" >&2
  printf '  binary %s\n' "${exe:-unknown}" >&2
  printf '  keeps %s sessions per project (its own env, read at ITS start)\n' "${keep:-?}" >&2
}

# End a daemon, loudly. Never reached without a confirmed decision.
end_daemon() {
  local pid="$1" reason="$2"
  local kids; kids="$(daemon_children "$pid")"
  local n=0; [ -n "$kids" ] && n="$(printf '%s\n' "$kids" | wc -l | tr -d ' ')"
  say "ending daemon pid $pid — $reason"
  say "this ENDS $n live pty session(s). They do not come back."
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    alive "$pid" || break
    /bin/sleep 0.2
  done
  if alive "$pid"; then
    warn "pid $pid did not stop on SIGTERM; leaving it alone rather than SIGKILLing a pty owner"
    warn "stop it yourself, then re-run: kill -9 $pid"
    return 1
  fi
  rm -f "$RUN_FILE"
  say "daemon pid $pid stopped"
}

confirm_end() {
  local pid="$1" reason="$2"
  local kids; kids="$(daemon_children "$pid")"
  local n=0; [ -n "$kids" ] && n="$(printf '%s\n' "$kids" | wc -l | tr -d ' ')"
  printf '\n' >&2
  warn "=============================================================="
  warn "ABOUT TO END A RUNNING juancoded — this kills live agent ptys."
  warn "=============================================================="
  warn "$reason"
  describe_running "$pid"
  warn "  it currently owns $n child process(es):"
  if [ -n "$kids" ]; then
    ps -o pid=,etime=,command= -p $(printf '%s' "$kids" | tr '\n' ',' | sed 's/,$//') 2>/dev/null \
      | sed 's/^/    /' >&2 || true
  fi
  printf '\n' >&2
  case "${JUANCODE_DAEMON:-ask}" in
    restart) say "JUANCODE_DAEMON=restart — not asking"; return 0 ;;
    adopt|off) return 1 ;;
  esac
  if [ ! -t 0 ]; then
    warn "no terminal to ask on. Re-run with JUANCODE_DAEMON=restart to end it, or"
    warn "JUANCODE_DAEMON=adopt to keep it and live with the staleness warning."
    return 1
  fi
  local answer
  read -r -p "juancoded: end pid $pid and its $n session(s)? [y/N] " answer >&2 || answer=""
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

start_daemon() {
  local want="$1"
  mkdir -p "$DATA_DIR"
  # The daemon inherits THIS shell's environment, which is the entire point: a
  # JUANCODE_* set on the launch line has to reach the process that acts on it.
  # JUANCODE_BUILD_ID is stamped here and read by both sides, so the app can prove an
  # exact match rather than inferring one from a file mtime.
  JUANCODE_BUILD_ID="$want" nohup "$BIN" >>"$LOG_FILE" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  for _ in $(seq 1 100); do
    healthy && break
    alive "$pid" || { warn "daemon exited during start; last lines of $LOG_FILE:"; tail -20 "$LOG_FILE" >&2; return 1; }
    /bin/sleep 0.1
  done
  if ! healthy; then
    warn "daemon did not answer /health on :$PORT within 10s; last lines of $LOG_FILE:"
    tail -20 "$LOG_FILE" >&2
    return 1
  fi
  say "started daemon pid $pid on :$PORT, build $want (log: $LOG_FILE)"
  say "it OUTLIVES this app on purpose — \`$SCRIPTS/juancoded.sh stop\` is what ends it"
}

build_daemon() {
  [ "${JUANCODE_SKIP_DAEMON_BUILD:-0}" = "1" ] && return 0
  say "building juancoded"
  cargo build --manifest-path "$MANIFEST" -p juancoded >&2
}

# Which core this launch will actually use, decided the same way CoreBoot does:
# JUANCODE_CORE wins, else the persisted Settings choice, else swift.
selected_core() {
  local core="${JUANCODE_CORE:-}"
  if [ -z "$core" ]; then
    core="$(defaults read dev.juancode.app juancode.core.backend 2>/dev/null || echo swift)"
  fi
  printf '%s' "$core"
}

cmd_status() {
  local pid; pid="$(run_get pid)"
  if [ -z "$pid" ] || ! alive "$pid"; then
    say "no daemon recorded as running (no live pid in $RUN_FILE)"
    healthy && warn "…but something IS answering :$PORT/health. It did not write a run file, so its build cannot be checked."
    return 0
  fi
  say "daemon running:"
  describe_running "$pid"
  local want theirs; want="$(build_id)"; theirs="$(run_get build_id)"
  if [ -z "$theirs" ]; then
    warn "  build: UNSTAMPED — started outside this script, so it cannot be matched to the checkout"
  elif [ "$theirs" = "$want" ]; then
    say "  build: $theirs (matches this checkout)"
  else
    warn "  build: $theirs — this checkout builds $want. THE DAEMON IS STALE."
  fi
  healthy || warn "  it is NOT answering :$PORT/health"
}

# Adopt or start, for the app-launch path. Prints one line either way, because the
# thing that went wrong was a daemon nobody could see.
cmd_ensure() {
  if [ "${JUANCODE_DAEMON:-ask}" = "off" ]; then
    say "JUANCODE_DAEMON=off — not touching the daemon"
    return 0
  fi
  local core; core="$(selected_core)"
  if [ "$core" != "rust" ]; then
    # Nothing to manage, and nothing to kill: the Swift core is in-process.
    return 0
  fi
  build_daemon
  local want; want="$(build_id)"
  local pid; pid="$(run_get pid)"

  if [ -n "$pid" ] && alive "$pid"; then
    local theirs; theirs="$(run_get build_id)"
    local reason=""
    if ! healthy; then
      reason="pid $pid is alive but not answering :$PORT/health — it is hung, not serving."
    elif [ -z "$theirs" ]; then
      reason="pid $pid was started outside this script, so its build is unstamped and cannot be matched to the checkout."
    elif [ "$theirs" != "$want" ]; then
      reason="pid $pid is build $theirs; this checkout builds $want. Nothing you compiled since then is running."
    fi
    if [ -z "$reason" ]; then
      local kids n=0; kids="$(daemon_children "$pid")"
      [ -n "$kids" ] && n="$(printf '%s\n' "$kids" | wc -l | tr -d ' ')"
      say "adopted daemon pid $pid on :$PORT, build $want, $n live session(s)"
      say "it OUTLIVES this app — \`$SCRIPTS/juancoded.sh status\` shows it, \`stop\` ends it"
      return 0
    fi
    if confirm_end "$pid" "$reason"; then
      end_daemon "$pid" "restarting onto build $want" || return 1
    else
      warn "keeping the running daemon. The app will show it as STALE in the core badge:"
      warn "  $reason"
      warn "Anything you set on this launch line reached the app only, not that daemon."
      return 0
    fi
  elif healthy; then
    # Something is serving the port with no run file behind it — exactly the orphan
    # this whole change is about, from before the run file existed.
    warn "something is answering :$PORT/health but wrote no run file, so its build is unknown."
    warn "That is the orphaned-daemon shape this script exists to end. Find and stop it:"
    warn "  lsof -nP -iTCP:$PORT -sTCP:LISTEN"
    warn "The app will flag it as stale if it is too old to identify itself."
    return 0
  fi
  start_daemon "$want"
}

cmd_stop() {
  local pid; pid="$(run_get pid)"
  if [ -z "$pid" ] || ! alive "$pid"; then
    say "nothing to stop"
    rm -f "$RUN_FILE"
    return 0
  fi
  if confirm_end "$pid" "you asked to stop it."; then
    end_daemon "$pid" "asked to stop"
  else
    say "left it running"
  fi
}

cmd_restart() {
  build_daemon
  local want; want="$(build_id)"
  local pid; pid="$(run_get pid)"
  if [ -n "$pid" ] && alive "$pid"; then
    confirm_end "$pid" "you asked to restart it onto build $want." || { say "left it running"; return 0; }
    end_daemon "$pid" "restarting onto build $want" || return 1
  fi
  start_daemon "$want"
}

case "${1:-ensure}" in
  ensure)   cmd_ensure ;;
  build-id) build_id; printf '\n' ;;
  status)   cmd_status ;;
  stop)     cmd_stop ;;
  restart)  cmd_restart ;;
  *) warn "unknown command: $1 (want: ensure|status|stop|restart|build-id)"; exit 2 ;;
esac
