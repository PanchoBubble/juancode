#!/usr/bin/env bash
# Install, inspect and remove the LaunchAgent that keeps `juancoded` — the Rust core —
# running, so `JUANCODE_CORE=rust` lands on the Rust core after a relaunch, a logout, or
# a reboot, with no terminal open anywhere.
#
# WHAT PROBLEM THIS SOLVES. Nothing in the repo used to start the daemon. You could set
# the core to rust in Settings, relaunch, and come up on the SWIFT core with an
# unreachable-daemon reason in the badge — unless you happened to have left `cargo run -p
# juancoded` in a terminal, in which case closing that terminal killed every live agent
# pty. `dev-app.sh` closed the terminal-launch half of that (it starts a daemon this
# launch owns). This closes the rest: a Dock launch, a login, a reboot.
#
# WHAT IT DELIBERATELY DOES NOT DO: RESTART ON A REBUILD.
#
# Restarting the daemon ends every pty it owns. A supervisor that "helpfully" restarted
# after a `cargo build` is a supervisor that silently kills five running agents, so:
#
#   * `serve` never builds. It runs whatever binary is in the checkout's target dir.
#   * a launchd daemon on an older build than the checkout is WARNED about on every app
#     launch (the `launchd` case in juancoded.sh's `cmd_ensure`) and left running.
#   * moving it onto a new build is `juancoded-agent.sh restart`, which counts the live
#     sessions and asks first.
#
# KeepAlive is set to restart on a CRASH only, which is the one case where the ptys are
# already gone whatever we do. See `write_plist` for what each key does.
#
# THE LOG STARTS WITH SHELL NOISE, AND THAT IS FINE. `serve` runs the user's rc files
# through an interactive shell with no tty, so `~/.juancode/logs/juancoded.error.log`
# opens with whatever they say about that — here, two `can't change option: zle` lines
# from zsh's line editor. Nothing is wrong; the daemon's own log follows.
#
# THE PLIST NAMES ONE CHECKOUT. There is one agent for the machine, and its
# ProgramArguments carry the absolute path of the checkout that installed it. `status`
# says so when you are standing in a different worktree, because a daemon serving
# another checkout's build is exactly the staleness this area of the code is about.
#
# Usage:
#   juancoded-agent.sh install     # write the plist and start the job
#   juancoded-agent.sh uninstall   # stop the job and remove the plist (ends its ptys)
#   juancoded-agent.sh status      # is it installed, loaded, running, and on what build
#   juancoded-agent.sh start       # start the job now (no-op if already running)
#   juancoded-agent.sh stop        # stop the job; it returns at the next login
#   juancoded-agent.sh restart     # onto the current build — ENDS ITS PTYS, asks first
#   juancoded-agent.sh log         # tail the daemon's launchd log
#
# Env:
#   JUANCODE_CONFIG=debug|release   which profile the job runs. Pinned INTO the plist at
#                                   install time, because `serve` does not build and so
#                                   cannot pick a profile at start.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
DAEMON_SH="$SCRIPTS/juancoded.sh"
MANIFEST="$ROOT/apps/juancoded/Cargo.toml"
CONFIG="${JUANCODE_CONFIG:-debug}"

# Matches the beads-dolt agent already on this machine: com.juanone.<thing>, plist in
# the user's LaunchAgents, logs under ~/.juancode/logs.
LABEL="com.juanone.juancoded"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.juancode/logs"
OUT_LOG="$LOG_DIR/juancoded.log"
ERR_LOG="$LOG_DIR/juancoded.error.log"
# `gui/<uid>` is the per-login-session domain: an Aqua agent, gone at logout and back at
# login, which is what a process holding a GUI app's ptys should be. Not `user/<uid>`,
# which would survive logout with no session to serve.
DOMAIN="gui/$(id -u)"
TARGET="$DOMAIN/$LABEL"

say()  { printf 'juancoded-agent: %s\n' "$*" >&2; }
warn() { printf 'juancoded-agent: %s\n' "$*" >&2; }

loaded() { launchctl print "$TARGET" >/dev/null 2>&1; }

# A pid is not readiness. For the first seconds of a `serve`, the pid launchd reports is
# the `$SHELL -lic` doing the environment import, and reporting then shows a job that is
# up beside a daemon that has not written its run file — which reads as broken. Wait for
# the socket instead. Generous, because the `-lic` probe is 1.5-5s on this machine and
# slower under load.
wait_healthy() {
  local waited=0
  while ! curl -fsS --max-time 2 "http://127.0.0.1:${JUANCODED_PORT:-4290}/health" >/dev/null 2>&1; do
    [ "$waited" -ge 120 ] && return 1
    /bin/sleep 0.5
    waited=$((waited + 1))
  done
}

# The daemon's pid as launchd knows it, empty when the job is loaded but not running.
job_pid() {
  launchctl print "$TARGET" 2>/dev/null | sed -n 's/^[[:space:]]*pid = \([0-9]*\)$/\1/p' | head -1
}

# The path the installed plist points at, so `status` can notice it is another checkout.
installed_root() {
  [ -f "$PLIST" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST" 2>/dev/null \
    | sed 's|/apps/native/scripts/juancoded.sh$||'
}

installed_config() {
  [ -f "$PLIST" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:JUANCODE_CONFIG' "$PLIST" 2>/dev/null || true
}

require_binary() {
  local bin="$ROOT/apps/juancoded/target/$CONFIG/juancoded"
  [ -x "$bin" ] && return 0
  warn "no $CONFIG daemon binary at $bin"
  warn "Build it first — the agent deliberately does not build at login:"
  warn "  cargo build --manifest-path $MANIFEST -p juancoded$([ "$CONFIG" = release ] && printf ' --release')"
  return 1
}

# Every key here is a decision about what happens on a crash, at logout and on a manual
# stop. Spelled out because getting one of them wrong costs live agent sessions.
write_plist() {
  mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
  cat > "$PLIST.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<!-- juancoded.sh serve, not the binary: the daemon spawns the agent CLIs, and
	     launchd's environment has none of the user's PATH or keys in it. \`serve\`
	     re-execs through \$SHELL -lic first so the daemon inherits a real login
	     environment. It also records that launchd owns this daemon, which is what stops
	     an app launch from claiming and then reaping it. -->
	<key>ProgramArguments</key>
	<array>
		<string>$DAEMON_SH</string>
		<string>serve</string>
	</array>
	<key>WorkingDirectory</key>
	<string>$ROOT</string>
	<key>EnvironmentVariables</key>
	<dict>
		<!-- Pinned at install time: \`serve\` does not build, so it cannot decide a
		     profile at start. -->
		<key>JUANCODE_CONFIG</key>
		<string>$CONFIG</string>
	</dict>
	<!-- Start at login, and at install. -->
	<key>RunAtLoad</key>
	<true/>
	<!-- Restart on a CRASH ONLY. SuccessfulExit=false means: relaunch when the daemon
	     exits NONZERO, leave it stopped when it exits 0. So a crash comes back (its
	     ptys were gone regardless), while \`launchctl stop\`, \`juancoded.sh stop\` and
	     \`serve\` finding no binary all exit 0 and stay stopped. A bare
	     \`KeepAlive: true\` — the beads-dolt precedent — would resurrect a daemon you
	     deliberately stopped, which for this process means fighting a human over a
	     port. -->
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<!-- Floor on how fast a crash loop can spin. launchd's default is 10s; set
	     explicitly so a login-time failure cannot pin a core. -->
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<!-- SIGTERM to SIGKILL on a stop. The daemon is the only writer of its SQLite and a
	     hard kill mid-write is how you get a torn WAL, so it gets longer than launchd's
	     20s default. -->
	<key>ExitTimeOut</key>
	<integer>30</integer>
	<!-- Not eligible for background throttling: this process is holding the ptys of
	     interactive agent sessions a human is watching. -->
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$OUT_LOG</string>
	<key>StandardErrorPath</key>
	<string>$ERR_LOG</string>
</dict>
</plist>
PLIST
  mv -f "$PLIST.tmp" "$PLIST"
  plutil -lint "$PLIST" >/dev/null
}

# `bootout` then `bootstrap`: a plist edited under a loaded job changes nothing until
# the job is reloaded, and that has bitten every LaunchAgent anyone has ever written.
bootstrap_job() {
  launchctl bootout "$TARGET" >/dev/null 2>&1 || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
}

cmd_install() {
  require_binary
  [ -x "$DAEMON_SH" ] || { warn "$DAEMON_SH is not executable"; return 1; }
  local prior; prior="$(installed_root)"
  if [ -n "$prior" ] && [ "$prior" != "$ROOT" ]; then
    warn "an agent is already installed pointing at a DIFFERENT checkout:"
    warn "  $prior"
    warn "Installing from here repoints it at $ROOT and restarts the job, which ENDS"
    warn "every pty the running daemon owns. Run \`$0 status\` first, then re-run"
    warn "install if you meant it."
    local answer
    [ -t 0 ] || { warn "no terminal to ask on; not repointing it."; return 1; }
    read -r -p "juancoded-agent: repoint the agent at $ROOT? [y/N] " answer >&2 || answer=""
    case "$answer" in y|Y) ;; *) say "left it pointing at $prior"; return 0 ;; esac
  fi
  write_plist
  say "wrote $PLIST"
  bootstrap_job
  say "bootstrapped $TARGET"
  wait_healthy || warn "it did not answer :${JUANCODED_PORT:-4290}/health within 60s"
  cmd_status
}

cmd_uninstall() {
  local pid; pid="$(job_pid)"
  if [ -n "$pid" ]; then
    local kids; kids="$(pgrep -P "$pid" 2>/dev/null | wc -l | tr -d ' ')"
    warn "=============================================================="
    warn "REMOVING THE AGENT ENDS THE RUNNING DAEMON (pid $pid)."
    warn "=============================================================="
    warn "It owns $kids child process(es). They do not come back."
    if [ -t 0 ]; then
      local answer
      read -r -p "juancoded-agent: remove the agent and end pid $pid? [y/N] " answer >&2 || answer=""
      case "$answer" in y|Y) ;; *) say "left it installed and running"; return 0 ;; esac
    else
      warn "no terminal to ask on; leaving it installed."
      return 1
    fi
  fi
  launchctl bootout "$TARGET" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  say "booted out $TARGET and removed $PLIST"
  say "the app will fall back to the Swift core on the next launch unless something else"
  say "starts a daemon (\`$SCRIPTS/dev-app.sh\` does)"
}

cmd_start() {
  loaded || { warn "not loaded. \`$0 install\` first."; return 1; }
  launchctl kickstart "$TARGET"
  say "kickstarted $TARGET"
}

cmd_stop() {
  loaded || { warn "not loaded; nothing to stop"; return 0; }
  local pid; pid="$(job_pid)"
  [ -n "$pid" ] || { say "loaded but not running; nothing to stop"; return 0; }
  local kids; kids="$(pgrep -P "$pid" 2>/dev/null | wc -l | tr -d ' ')"
  warn "stopping pid $pid ENDS $kids child process(es). They do not come back."
  if [ -t 0 ]; then
    local answer
    read -r -p "juancoded-agent: stop pid $pid? [y/N] " answer >&2 || answer=""
    case "$answer" in y|Y) ;; *) say "left it running"; return 0 ;; esac
  else
    warn "no terminal to ask on; leaving it running."
    return 1
  fi
  launchctl stop "$TARGET"
  say "stopped. KeepAlive is SuccessfulExit=false, so it stays stopped until"
  say "\`$0 start\` or your next login."
}

# The ONLY thing that moves a launchd daemon onto a new build, and the reason nothing
# does it automatically: it ends every pty the current one owns.
cmd_restart() {
  loaded || { warn "not loaded. \`$0 install\` first."; return 1; }
  require_binary
  local pid; pid="$(job_pid)"
  if [ -n "$pid" ]; then
    local kids; kids="$(pgrep -P "$pid" 2>/dev/null | wc -l | tr -d ' ')"
    warn "=============================================================="
    warn "RESTARTING ENDS THE RUNNING DAEMON (pid $pid) AND ITS PTYS."
    warn "=============================================================="
    warn "It owns $kids child process(es). They do not come back."
    ps -o pid=,etime=,command= -p "$pid" 2>/dev/null | sed 's/^/    /' >&2 || true
    if [ -t 0 ]; then
      local answer
      read -r -p "juancoded-agent: restart onto build $("$DAEMON_SH" build-id) and end $kids child process(es)? [y/N] " answer >&2 || answer=""
      case "$answer" in y|Y) ;; *) say "left it running"; return 0 ;; esac
    else
      warn "no terminal to ask on; leaving it running."
      return 1
    fi
  fi
  # `-k` sends SIGKILL to the running job first; the daemon takes SIGTERM cleanly, so
  # stop-then-start is the orderly spelling and this is the one that matches it.
  launchctl kickstart -k "$TARGET"
  say "restarted $TARGET"
  wait_healthy || warn "it did not answer :${JUANCODED_PORT:-4290}/health within 60s"
  cmd_status
}

cmd_status() {
  if [ ! -f "$PLIST" ]; then
    say "NOT installed (no $PLIST)"
    say "  \`$0 install\` writes it. Until then, only \`dev-app.sh\` starts a daemon, and"
    say "  only for as long as that terminal lives."
  else
    say "installed: $PLIST"
    local where cfg
    where="$(installed_root)"; cfg="$(installed_config)"
    if [ -n "$where" ] && [ "$where" != "$ROOT" ]; then
      warn "  it runs ANOTHER CHECKOUT: $where"
      warn "  you are in $ROOT — its daemon serves that checkout's build, not yours"
    else
      say "  checkout: ${where:-unknown} (this one)"
    fi
    say "  profile:  ${cfg:-unset}"
  fi
  if loaded; then
    local pid; pid="$(job_pid)"
    if [ -n "$pid" ]; then
      say "loaded and RUNNING, pid $pid"
    else
      say "loaded but NOT running (crashed and throttled, or stopped)"
      say "  last lines of $ERR_LOG:"
      tail -5 "$ERR_LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
    fi
  else
    say "not loaded in $DOMAIN"
  fi
  # The daemon's own account of itself: build, ownership, watchdog, port. The one that
  # answers "is it stale", which is the question a supervisor must never act on alone.
  printf '\n' >&2
  "$DAEMON_SH" status || true
}

cmd_log() { tail -n "${2:-40}" -f "$OUT_LOG"; }

case "${1:-status}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  restart)   cmd_restart ;;
  status)    cmd_status ;;
  log)       cmd_log "$@" ;;
  *) warn "unknown command: $1 (want: install|uninstall|start|stop|restart|status|log)"; exit 2 ;;
esac
