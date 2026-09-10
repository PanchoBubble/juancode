#!/usr/bin/env bash
# Own the `juancoded` daemon's lifetime, so launching the app cannot leave you
# talking to a core from two hours ago.
#
# THE BUG THIS EXISTS FOR
#
# The daemon is a separate process. Nothing owned its lifetime, so it drifted to
# PPID 1 and stayed there across app restarts. Relaunching the app just reconnected
# to whatever was still listening on 4290 — an older build, with the environment IT
# was started with. The app's session list is a mirror of what that daemon reports,
# so it looked authoritative while being hours stale, and a
# JUANCODE_SESSIONS_PER_PROJECT set on the app's launch line pruned nothing because
# the daemon never saw it.
#
# THE INVARIANT
#
# After an app launch, the daemon is from the CURRENT source and is YOUNGER than the
# app. Two rules get there:
#
#   1. Always `cargo build` before starting. Cargo does the change detection; a build
#      failure fails the launch rather than falling back to the stale binary, because
#      a stale binary is the whole bug.
#   2. A launch that STARTS a daemon OWNS it, and reaps it when the app exits (see the
#      trap in dev-app.sh). The daemon no longer outlives the app.
#   3. The daemon enforces rule 2 from ITS side too. A trap cannot fire in a shell that
#      was SIGKILLed, and macOS has no PDEATHSIG, so the owner's pid is handed to the
#      daemon at spawn and the daemon ends ITSELF once that pid is gone for the grace
#      period (crates/juancoded-server/src/owner.rs). Rule 2 covers every ordinary
#      exit; rule 3 is what covers the ones bash never sees.
#
# Rule 2 has a real cost, stated plainly: live agent ptys do NOT survive quitting the
# app any more. That is the trade for never being able to read a stale mirror.
#
# Rule 3 only ever applies to a daemon somebody CLAIMED. An unowned one — `cargo run -p
# juancoded`, or one a developer keeps alive deliberately — is never handed an owner,
# so its watchdog is inert and it outlives everything, which is the point.
#
# WHEN THE INVARIANT CANNOT HOLD
#
# Something already listening that this launch did not start is FOREIGN. It is not
# adopted and it is not killed — this script says so, loudly, and the boot handshake
# flags it on screen (`rust · stale` in the core badge). Ending somebody else's daemon
# ends somebody else's ptys, so that is always an explicit command, never a side
# effect of launching.
#
# NEVER pkill BY NAME. A `pkill -f juancoded` would also end the daemon belonging to
# another worktree, and that one is holding real ptys. Only the exact pid this launch
# recorded is ever signalled.
#
# THE FOURTH KIND OF DAEMON: launchd's
#
# A daemon started by the LaunchAgent (`juancoded-agent.sh install`, label
# com.juanone.juancoded) is a fifth state beside ours/unowned/foreign/none, and it has
# to be, because everything above assumes the daemon's lifetime belongs to a launch
# shell. launchd's does not. It is recorded as `managed=launchd` in the ownership file
# by `juancoded.sh serve`, and the two rules for it are absolute:
#
#   * it is NEVER claimed. Claiming it would arm the trap in dev-app.sh, and the app
#     quitting would then end a daemon launchd immediately restarts empty — five live
#     agents killed by closing a window.
#   * it is NEVER restarted because the build moved on. A stale launchd daemon is
#     WARNED about, on every launch, and left running. Restarting it is a human
#     command (`juancoded-agent.sh restart`) that counts the ptys first.
#
# Usage:
#   juancoded.sh ensure [token]  # build, then start (owned by `token`) or report foreign
#   juancoded.sh reap <token>    # end the daemon `token` owns: TERM, grace, then KILL
#   juancoded.sh status          # what is running, who owns it, does it match the checkout
#   juancoded.sh stop            # end whatever is running, after confirming
#   juancoded.sh restart         # stop, then start an unowned one
#   juancoded.sh serve           # run the daemon in the FOREGROUND, owned by launchd
#   juancoded.sh build-id        # print the checkout's build identity
#
# See also `juancoded-agent.sh`, which installs/removes the LaunchAgent that runs
# `serve`.
#
# Env:
#   JUANCODE_CONFIG=debug|release   which profile to build and run (matches dev-app.sh)
#   JUANCODE_DAEMON=off             do nothing at all; you are managing it yourself
#   JUANCODE_SKIP_DAEMON_BUILD=1    skip cargo (test harnesses only — reintroduces the bug)
#   JUANCODE_OWNER_GRACE_SECONDS=N  how long an ORPHANED daemon keeps serving before it
#                                   ends itself (default 120; 0 disables the watchdog)
#   JUANCODE_LOGIN_ENV=0            `serve` only: do NOT re-exec through `$SHELL -lic`
#                                   first. Only safe when the caller's environment is
#                                   already a login shell's.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/../../.." && pwd)"
SELF="$SCRIPTS/juancoded.sh"
MANIFEST="$ROOT/apps/juancoded/Cargo.toml"
CONFIG="${JUANCODE_CONFIG:-debug}"
# Shared with juancoded-agent.sh, which installs the plist that carries it.
AGENT_LABEL="com.juanone.juancoded"

# Mirrors `juancoded_persistence::db_path()` exactly. Two spellings of the same
# default in two languages is a drift waiting to happen; this one is the copy, and
# the run file's `data_dir` line is what proves they agreed.
DATA_DIR="${JUANCODED_DATA_DIR:-${JUANCODE_DATA_DIR:-$HOME/.juancode/rust-core}}"
# Written by the DAEMON, identity only (juancoded-server/src/identity.rs).
RUN_FILE="$DATA_DIR/juancoded.run"
# Written by THIS script, ownership only. Two files because they have two writers:
# one process must never be editing the other's record.
OWN_FILE="$DATA_DIR/juancoded.owner"
LOG_FILE="$DATA_DIR/juancoded.log"
PORT="${JUANCODED_PORT:-4290}"
BIN="${JUANCODE_JUANCODED_BIN:-$ROOT/apps/juancoded/target/$CONFIG/juancoded}"

# How long a daemon gets to flush and exit on SIGTERM before it is SIGKILLed. The
# store is its own SQLite and it is the only writer; a hard kill mid-write is how you
# get a torn WAL, so this is generous on purpose. juancoded takes SIGTERM through the
# same orderly shutdown as ctrl-c (see crates/juancoded/src/main.rs).
GRACE_SECONDS="${JUANCODE_DAEMON_GRACE:-10}"

# How long the DAEMON's own watchdog waits after its owner disappears before it ends
# itself. Unrelated to GRACE_SECONDS above (that one is TERM-to-KILL on a teardown we
# are driving); this one is the safety net for a teardown that never ran. Generous on
# purpose: it only ever runs after a bad death, and a short one would end live ptys
# during a legitimate relaunch. Read by juancoded as JUANCODE_OWNER_GRACE_SECONDS.
OWNER_GRACE_SECONDS="${JUANCODE_OWNER_GRACE_SECONDS:-120}"

say()  { printf 'juancoded: %s\n' "$*" >&2; }
warn() { printf 'juancoded: %s\n' "$*" >&2; }

# One field out of a record file. `sed`, not `source`: these are written by another
# process and must never be executed.
field() { [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | head -1 || true; }
run_get()  { field "$RUN_FILE" "$1"; }
own_get()  { field "$OWN_FILE" "$1"; }

alive()   { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }
healthy() { curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; }

# The identity of the build sitting in the checkout right now. A function of the
# BUILD, never of the launch.
build_id() {
  local sha dirty stamp
  sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
  dirty=""
  git -C "$ROOT" diff --quiet HEAD -- apps/juancoded 2>/dev/null || dirty="-dirty"
  stamp="$(stat -f %m "$BIN" 2>/dev/null || echo 0)"
  printf '%s%s-%s' "$sha" "$dirty" "$stamp"
}

# The ptys a teardown would end. This is the number that has to be on screen first.
daemon_children() { pgrep -P "$1" 2>/dev/null || true; }
child_count() {
  local kids; kids="$(daemon_children "$1")"
  [ -z "$kids" ] && { printf 0; return; }
  printf '%s' "$(printf '%s\n' "$kids" | wc -l | tr -d ' ')"
}

describe_running() {
  local pid="$1" started version keep exe
  started="$(run_get started_at_ms)"; exe="$(run_get exe)"
  version="$(run_get version)"; keep="$(run_get sessions_per_project)"
  local when="unknown"
  [ -n "$started" ] && when="$(date -r "$((started / 1000))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
  printf '  pid %s, v%s, up since %s\n' "$pid" "${version:-?}" "$when" >&2
  printf '  binary %s\n' "${exe:-unknown}" >&2
  printf '  keeps %s sessions per project (its own env, read at ITS start)\n' "${keep:-?}" >&2
  printf '  owns %s child process(es)\n' "$(child_count "$pid")" >&2
}

# Whoever is listening, is it ours? Answers on stdout: `ours`, `launchd`, `unowned`
# or `foreign`. A recorded owner whose own process is gone counts as unowned — a launch
# that was SIGKILLed never ran its trap, and its claim must not strand the daemon
# forever.
#
# `launchd` is checked before anything else about the record, and deliberately does not
# depend on `alive "$owner_pid"`: that record names pid 1, which a non-root `kill -0`
# reports as unsignalable, so the generic path below would read launchd's daemon as
# UNOWNED and adopt it. Adopting it is the one outcome this whole file exists to
# prevent.
ownership() {
  local pid="$1" token="$2"
  local owner_daemon owner_token owner_pid owner_managed
  owner_daemon="$(own_get daemon_pid)"; owner_token="$(own_get token)"; owner_pid="$(own_get owner_pid)"
  owner_managed="$(own_get managed)"
  [ "$owner_daemon" = "$pid" ] || { printf 'foreign'; return; }
  [ "$owner_managed" = "launchd" ] && { printf 'launchd'; return; }
  [ -n "$token" ] && [ "$owner_token" = "$token" ] && { printf 'ours'; return; }
  if [ -z "$owner_token" ] || ! alive "$owner_pid"; then printf 'unowned'; else printf 'foreign'; fi
}

# `owner_pid` is passed in rather than taken from $PPID: `ensure` is called inside a
# command substitution so the caller can read its verdict, and $PPID there is the
# short-lived subshell, not the launch. An owner that is dead by definition would make
# every daemon read as unowned.
claim() {
  local pid="$1" token="$2" owner_pid="$3"
  mkdir -p "$DATA_DIR"
  {
    printf 'daemon_pid=%s\n' "$pid"
    printf 'token=%s\n' "$token"
    printf 'owner_pid=%s\n' "$owner_pid"
  } > "$OWN_FILE.tmp"
  mv -f "$OWN_FILE.tmp" "$OWN_FILE"
}

# The same record, for the daemon launchd is about to become (see `cmd_serve`). Written
# BEFORE the exec, so the pid it names is the pid the daemon will have.
#
# `owner_pid=1` is not a placeholder. juancoded's own watchdog drops any owner pid <= 1
# on purpose (`Claim::owner_of` in owner.rs: launchd is what a process gets reparented
# TO, so a record naming it names an owner that cannot be waited on), which is exactly
# the reading we want — launchd's daemon has no launch shell to outlive, so the
# self-exit countdown must never arm for it. `cmd_serve` also passes
# JUANCODE_OWNER_GRACE_SECONDS=0, so that is true from two directions.
claim_launchd() {
  local pid="$1"
  mkdir -p "$DATA_DIR"
  {
    printf 'daemon_pid=%s\n' "$pid"
    printf 'token=%s\n' "$AGENT_LABEL"
    printf 'owner_pid=1\n'
    printf 'managed=launchd\n'
  } > "$OWN_FILE.tmp"
  mv -f "$OWN_FILE.tmp" "$OWN_FILE"
}

# TERM, wait out the grace period, then KILL. The only path that ever signals.
end_daemon() {
  local pid="$1" reason="$2"
  local n; n="$(child_count "$pid")"
  say "ending daemon pid $pid — $reason"
  say "this ENDS $n live pty session(s). They do not come back."
  kill -TERM "$pid" 2>/dev/null || true
  local waited=0
  while alive "$pid" && [ "$waited" -lt "$((GRACE_SECONDS * 5))" ]; do
    /bin/sleep 0.2
    waited=$((waited + 1))
  done
  if alive "$pid"; then
    warn "pid $pid ignored SIGTERM for ${GRACE_SECONDS}s; SIGKILLing it"
    warn "its store may not have flushed cleanly — check $LOG_FILE"
    kill -9 "$pid" 2>/dev/null || true
    /bin/sleep 0.3
  fi
  rm -f "$OWN_FILE"
  # The daemon removes its own run file on an orderly exit; clear it here too so a
  # SIGKILLed one does not leave a file naming a dead pid.
  [ "$(run_get pid)" = "$pid" ] && rm -f "$RUN_FILE"
  say "daemon pid $pid stopped"
}

confirm_end() {
  local pid="$1" reason="$2"
  printf '\n' >&2
  warn "=============================================================="
  warn "ABOUT TO END A RUNNING juancoded — this kills live agent ptys."
  warn "=============================================================="
  warn "$reason"
  describe_running "$pid"
  local kids; kids="$(daemon_children "$pid")"
  if [ -n "$kids" ]; then
    ps -o pid=,etime=,command= -p "$(printf '%s' "$kids" | tr '\n' ',' | sed 's/,$//')" 2>/dev/null \
      | sed 's/^/    /' >&2 || true
  fi
  printf '\n' >&2
  if [ ! -t 0 ]; then
    warn "no terminal to ask on; leaving it running."
    return 1
  fi
  local answer
  read -r -p "juancoded: end pid $pid and its $(child_count "$pid") session(s)? [y/N] " answer >&2 || answer=""
  [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

# Always. Cargo does the change detection and no-ops when nothing moved; what must not
# happen is launching a binary older than the checkout.
build_daemon() {
  if [ "${JUANCODE_SKIP_DAEMON_BUILD:-0}" = "1" ]; then
    warn "JUANCODE_SKIP_DAEMON_BUILD=1 — NOT rebuilding. You may be running a stale core."
    return 0
  fi
  say "building juancoded ($CONFIG)"
  local args=(build --manifest-path "$MANIFEST" -p juancoded)
  [ "$CONFIG" = "release" ] && args+=(--release)
  if ! cargo "${args[@]}" >&2; then
    warn "cargo build FAILED. Refusing to start a daemon from the stale binary at:"
    warn "  $BIN"
    warn "Fix the build; launching on an older core than your checkout is the bug this guards."
    return 1
  fi
}

# Which core this launch will actually use, decided the same way CoreBoot does:
# JUANCODE_CORE wins, else the persisted Settings choice, else swift.
#
# Two defaults domains, because this repo builds the app under two bundle identifiers —
# `dev.juancode.app` (apps/native/scripts/dev-app.sh and package-app.sh) and
# `com.juanone.juancode` (scripts/bundle-app.sh) — and UserDefaults is per-identifier.
# Reading only one of them is a way to flip the setting to rust in the app, relaunch,
# and have this script decide there was nothing to start: the exact symptom of
# juancode-k0bq, from the other end. First domain that has an answer wins; `rust`
# anywhere is enough, since the cost of starting a daemon the app then ignores is one
# idle process and the cost of not starting one is the Swift-core fallback.
selected_core() {
  local core="${JUANCODE_CORE:-}" domain
  if [ -z "$core" ]; then
    for domain in dev.juancode.app com.juanone.juancode; do
      core="$(defaults read "$domain" juancode.core.backend 2>/dev/null || true)"
      [ -n "$core" ] && break
    done
  fi
  printf '%s' "${core:-swift}"
}

start_daemon() {
  local want="$1" token="$2" owner_pid="${3:-0}"
  mkdir -p "$DATA_DIR"
  say "starting $BIN"
  say "  build $want, profile $CONFIG, port $PORT"
  # The daemon inherits THIS shell's environment, which is the entire point: a
  # JUANCODE_* set on the launch line has to reach the process that acts on it.
  # JUANCODE_BUILD_ID is stamped here and read by both sides, so the app can prove an
  # exact match rather than inferring one from a file mtime.
  #
  # JUANCODE_OWNER_PID is the other half of the lifetime contract: the trap below
  # reaps this daemon on every exit bash can see, and this tells the daemon whose
  # death to watch for on the exits bash CANNOT see (SIGKILL, a vanished terminal).
  # It is set only when this launch is actually claiming ownership — an unowned start
  # must stay unowned, or a `--print-bin` invocation that exits immediately would tell
  # the daemon its owner had already died.
  local claiming=0
  if [ -n "$token" ] && [ "$owner_pid" != "0" ]; then
    claiming=1
    say "  owned by pid $owner_pid; it self-exits ${OWNER_GRACE_SECONDS}s after that pid is gone"
  else
    say "  UNOWNED: no watchdog. Nothing will end it but \`juancoded.sh stop\`."
  fi
  # A subshell that `export`s and then `exec`s, rather than an assignment prefix built
  # up in a variable. Bash decides what is an assignment prefix when it PARSES the
  # line, so a word that only expands into `FOO=1` is read as the command name — that
  # spelling silently started no daemon at all and reported `command not found`.
  # `exec` keeps the pid: the subshell becomes nohup, which becomes the daemon, so `$!`
  # is the daemon's own pid and the ownership record names the right process.
  (
    export JUANCODE_BUILD_ID="$want"
    export JUANCODE_OWNER_GRACE_SECONDS="$OWNER_GRACE_SECONDS"
    [ "$claiming" = "1" ] && export JUANCODE_OWNER_PID="$owner_pid"
    exec nohup "$BIN" >>"$LOG_FILE" 2>&1
  ) &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  local waited=0
  while ! healthy; do
    alive "$pid" || { warn "daemon exited during start; last lines of $LOG_FILE:"; tail -20 "$LOG_FILE" >&2; return 1; }
    [ "$waited" -ge 100 ] && { warn "no /health on :$PORT within 10s; last lines of $LOG_FILE:"; tail -20 "$LOG_FILE" >&2; return 1; }
    /bin/sleep 0.1
    waited=$((waited + 1))
  done
  claim "$pid" "$token" "$owner_pid"
  if [ -n "$token" ]; then
    say "started pid $pid, owned by this launch — it is reaped when the app exits"
  else
    say "started pid $pid, UNOWNED — nothing will reap it. Stop it with \`$SCRIPTS/juancoded.sh stop\`"
  fi
  printf 'started %s\n' "$pid"
}

cmd_status() {
  local pid; pid="$(run_get pid)"
  if [ -z "$pid" ] || ! alive "$pid"; then
    say "no daemon recorded as running (no live pid in $RUN_FILE)"
    healthy && warn "…but something IS answering :$PORT/health. It wrote no run file, so its build cannot be checked."
    return 0
  fi
  say "daemon running:"
  describe_running "$pid"
  case "$(ownership "$pid" "")" in
    launchd) say "  owner: launchd ($AGENT_LABEL) — it survives logout and app quits"
             say "         no launch claims or reaps it; \`juancoded-agent.sh restart\` is the only restart" ;;
    unowned) say "  owner: nobody — nothing will reap it when an app exits" ;;
    *)       say "  owner: launch $(own_get token) (shell pid $(own_get owner_pid), $(alive "$(own_get owner_pid)" && echo alive || echo gone))" ;;
  esac
  local wpid wgrace; wpid="$(run_get owner_pid)"; wgrace="$(run_get owner_grace_ms)"
  if [ -z "$wgrace" ]; then
    warn "  watchdog: NONE — this daemon predates the self-exit watchdog and can orphan"
  elif [ "$wgrace" = "0" ]; then
    warn "  watchdog: DISABLED (JUANCODE_OWNER_GRACE_SECONDS=0) — it can outlive its owner"
  elif [ -z "$wpid" ]; then
    say "  watchdog: armed only by a claim (started with no owner); grace $((wgrace / 1000))s"
  else
    say "  watchdog: self-exits $((wgrace / 1000))s after pid $wpid is gone ($(alive "$wpid" && echo alive || echo GONE))"
  fi
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

# The app-launch path. Builds, then either starts a daemon this launch owns or reports
# the foreign one it refuses to touch. Never interactive: it is on the critical path of
# every launch, and a prompt there is a launch that hangs.
#
# Prints one machine-readable line on stdout for the caller's trap:
#   started <pid> | claimed <pid> | launchd <pid> | foreign <pid> | none
#
# Only `started` and `claimed` arm a trap. `launchd` and `foreign` both mean "connect
# to it, touch nothing"; `none` means the Swift core, or JUANCODE_DAEMON=off.
cmd_ensure() {
  local token="${1:-}" owner_pid="${2:-0}"
  if [ "${JUANCODE_DAEMON:-}" = "off" ]; then
    say "JUANCODE_DAEMON=off — not touching the daemon"
    printf 'none\n'
    return 0
  fi
  if [ "$(selected_core)" != "rust" ]; then
    # Nothing to manage and nothing to kill: the Swift core is in-process.
    printf 'none\n'
    return 0
  fi
  build_daemon
  local want; want="$(build_id)"
  local pid; pid="$(run_get pid)"

  if [ -n "$pid" ] && alive "$pid" && healthy; then
    local theirs; theirs="$(run_get build_id)"
    case "$(ownership "$pid" "$token")" in
      launchd)
        # launchd's, and therefore not this launch's to claim, reap or replace. The app
        # connects to it; the trap in dev-app.sh never arms (it arms on started/claimed
        # only), so quitting the app leaves it and its ptys exactly where they are.
        say "the daemon on :$PORT is managed by launchd ($AGENT_LABEL), pid $pid."
        say "  not claimed and not reaped — launchd owns its lifetime, not this launch"
        if [ "$theirs" = "$want" ]; then
          say "  build $theirs (matches this checkout), $(child_count "$pid") live session(s)"
        elif [ -z "$theirs" ]; then
          warn "  build UNSTAMPED — it cannot be matched against this checkout's $want."
          warn "  Nothing here restarts it. \`$SCRIPTS/juancoded-agent.sh restart\` does, deliberately."
        else
          warn "  build $theirs — THIS CHECKOUT BUILDS $want. THE DAEMON IS STALE."
          warn "  Nothing here restarts it: that would end $(child_count "$pid") live pty session(s)."
          warn "  When you are ready to lose them: \`$SCRIPTS/juancoded-agent.sh restart\`"
        fi
        printf 'launchd %s\n' "$pid"
        return 0
        ;;
      ours|unowned)
        if [ "$theirs" = "$want" ]; then
          claim "$pid" "$token" "$owner_pid"
          say "claimed the running daemon pid $pid (build $want, $(child_count "$pid") live session(s))"
          [ -n "$token" ] && say "it is reaped when this app exits"
          printf 'claimed %s\n' "$pid"
          return 0
        fi
        # Unowned AND stale: nobody is relying on it, so replacing it is the launch's
        # business — but it may still hold ptys, so it is announced, not silent.
        warn "the unowned daemon pid $pid is build $theirs; this checkout builds $want."
        warn "It holds $(child_count "$pid") pty session(s). Leaving it alone."
        warn "\`$SCRIPTS/juancoded.sh stop\` ends it, then relaunch to get a matching one."
        printf 'foreign %s\n' "$pid"
        return 0
        ;;
    esac
    warn "=============================================================="
    warn "A FOREIGN juancoded is already on :$PORT. Not adopting it."
    warn "=============================================================="
    warn "It was started by launch $(own_get token) (shell pid $(own_get owner_pid)), not by this one."
    describe_running "$pid"
    [ "$theirs" != "$want" ] && warn "  and it is build $theirs, not this checkout's $want — IT IS STALE."
    warn "This launch will not start or end a daemon. The app connects to that one and"
    warn "flags it in the core badge. \`$SCRIPTS/juancoded.sh stop\` ends it, deliberately."
    printf 'foreign %s\n' "$pid"
    return 0
  fi

  if healthy; then
    warn "something is answering :$PORT/health but wrote no run file, so its build is unknown."
    warn "That is the orphaned-daemon shape this script exists to end. Find and stop it:"
    warn "  lsof -nP -iTCP:$PORT -sTCP:LISTEN"
    warn "The app will flag it as stale if it is too old to identify itself."
    printf 'foreign unknown\n'
    return 0
  fi

  start_daemon "$want" "$token" "$owner_pid"
}

# The trap's half of `ensure`. Ends the daemon this launch owns and nothing else: a
# token mismatch means somebody took over in the meantime, and their daemon is theirs.
cmd_reap() {
  local token="${1:-}"
  [ -n "$token" ] || return 0
  local pid; pid="$(own_get daemon_pid)"
  [ -n "$pid" ] || return 0
  # Belt and braces: a launch never holds launchd's token, so the check below would
  # already refuse. Said explicitly because this is the signal that must never be sent.
  if [ "$(own_get managed)" = "launchd" ]; then
    say "daemon pid $pid is managed by launchd — not reaping it"
    return 0
  fi
  if [ "$(own_get token)" != "$token" ]; then
    say "daemon pid $pid is owned by launch $(own_get token) now, not $token — leaving it"
    return 0
  fi
  alive "$pid" || { rm -f "$OWN_FILE"; return 0; }
  end_daemon "$pid" "the app that started it exited"
}

# What the LaunchAgent runs. Stays in the FOREGROUND: launchd tracks the process it
# spawned, so a daemon put into the background here would look to launchd like a job
# that exited immediately and be restarted forever.
#
# THE ENVIRONMENT IS THE WHOLE DIFFICULTY. launchd hands a job a stripped environment —
# PATH is roughly /usr/bin:/bin:/usr/sbin:/sbin and nothing exported from .zshrc is
# there. For most daemons that is cosmetic. For this one it is fatal: juancoded SPAWNS
# claude/codex/opencode, and juancode's prime directive is that those processes see the
# user's real shell environment (PATH, MCP config, keys). So `serve` re-execs itself
# through `$SHELL -lic` first and lets the daemon inherit THAT.
#
# `-lic` and not `-lc`, for the reason already measured on this machine for the app's
# own import (JuancodeCore/LoginEnvironment.swift): `-lc` reports ~16 variables and
# none of the keys, because those are exported from .zshrc, which only `-i` sources.
# It costs 1.5-5.1s. That is paid once at login, and once per crash restart.
#
# DELIBERATELY NO cargo build HERE. Every other path in this file builds first, because
# a stale binary is the bug they exist for. This one must not:
#   * launchd starts it at login, where a build failure would mean no core at all and a
#     multi-second delay on every login;
#   * KeepAlive restarts it after a crash, and a cargo build in a restart loop is a
#     laptop that gets hot and never recovers.
# A launchd daemon therefore goes stale, and that is handled by SAYING SO on every app
# launch (see the `launchd` case in cmd_ensure) rather than by restarting it — a
# restart kills every pty it owns.
cmd_serve() {
  if [ -z "${JUANCODE_LOGIN_ENV_DONE:-}" ] && [ "${JUANCODE_LOGIN_ENV:-1}" != "0" ]; then
    local shell="${SHELL:-/bin/zsh}"
    if [ -x "$shell" ]; then
      say "importing the login environment via $shell -lic (the daemon spawns the agent CLIs)"
      export JUANCODE_LOGIN_ENV_DONE=1
      # `-c` with trailing words: $0 is the name, $1 the first argument. Building the
      # command with the path interpolated into the script text would break on any
      # path containing a quote.
      exec "$shell" -lic 'exec "$1" serve' juancoded-serve "$SELF"
    fi
    warn "\$SHELL=$shell is not executable; starting with launchd's stripped environment."
    warn "Agent CLIs spawned by this daemon may not find their PATH or their keys."
  fi

  if [ ! -x "$BIN" ]; then
    warn "no daemon binary at $BIN"
    warn "Build it once, then \`launchctl kickstart gui/$(id -u)/$AGENT_LABEL\`:"
    warn "  cargo build --manifest-path $MANIFEST -p juancoded"
    # Exit 0, on purpose, and this is the one counter-intuitive line in the file. The
    # LaunchAgent's KeepAlive is SuccessfulExit=false: a NONZERO exit is a crash and
    # gets restarted. Exiting nonzero here would put launchd into a restart loop over a
    # missing file that no amount of restarting creates. Exit 0 means "there is nothing
    # to run", and launchd leaves it alone until a human kickstarts it.
    exit 0
  fi

  mkdir -p "$DATA_DIR"
  # Before the exec, so the pid in the record is the pid the daemon will have.
  claim_launchd "$$"
  say "starting $BIN in the foreground under launchd ($AGENT_LABEL), pid $$"
  say "  port $PORT, data dir $DATA_DIR"
  say "  build $(build_id)"
  export JUANCODE_BUILD_ID="${JUANCODE_BUILD_ID:-$(build_id)}"
  # The self-exit watchdog is the wrong mechanism here and must be off: it ends a
  # daemon whose OWNING LAUNCH has died, and this daemon has no owning launch. launchd
  # is the supervisor. 0 is the documented switch (owner.rs: DEFAULT_GRACE).
  export JUANCODE_OWNER_GRACE_SECONDS=0
  # No JUANCODE_OWNER_PID: declaring an owner is what arms the countdown.
  unset JUANCODE_OWNER_PID
  exec "$BIN"
}

cmd_stop() {
  local pid; pid="$(run_get pid)"
  if [ -z "$pid" ] || ! alive "$pid"; then
    say "nothing to stop"
    rm -f "$RUN_FILE" "$OWN_FILE"
    return 0
  fi
  local managed=""; [ "$(ownership "$pid" "")" = "launchd" ] && managed=1
  if confirm_end "$pid" "you asked to stop it."; then
    end_daemon "$pid" "asked to stop"
    # SIGTERM takes juancoded through its orderly shutdown and it exits 0, which the
    # agent's KeepAlive (SuccessfulExit=false) reads as "meant it" — so it stays
    # stopped now, and comes back at the next login because RunAtLoad is set.
    [ -n "$managed" ] && say "launchd will start it again at your next login (or \`juancoded-agent.sh start\`)"
  else
    say "left it running"
  fi
}

cmd_restart() {
  build_daemon
  local want; want="$(build_id)"
  local pid; pid="$(run_get pid)"
  if [ -n "$pid" ] && alive "$pid"; then
    # A launchd-managed daemon must not be replaced by an unowned one: launchd is still
    # watching that slot, and the next login would start a second daemon that cannot
    # bind the port. That restart belongs to the agent script, which restarts the JOB.
    if [ "$(ownership "$pid" "")" = "launchd" ]; then
      warn "daemon pid $pid is managed by launchd ($AGENT_LABEL)."
      warn "Restart the job, not the process: \`$SCRIPTS/juancoded-agent.sh restart\`"
      return 1
    fi
    confirm_end "$pid" "you asked to restart it onto build $want." || { say "left it running"; return 0; }
    end_daemon "$pid" "restarting onto build $want"
  fi
  # Unowned: this invocation has no app to tie it to. The next `dev-app.sh` claims it.
  start_daemon "$want" "" 0
}

case "${1:-ensure}" in
  ensure)   shift || true; cmd_ensure "${1:-}" "${2:-0}" ;;
  reap)     shift || true; cmd_reap "${1:-}" ;;
  status)   cmd_status ;;
  stop)     cmd_stop ;;
  restart)  cmd_restart ;;
  serve)    cmd_serve ;;
  build-id) build_id; printf '\n' ;;
  *) warn "unknown command: $1 (want: ensure|reap|status|stop|restart|serve|build-id)"; exit 2 ;;
esac
