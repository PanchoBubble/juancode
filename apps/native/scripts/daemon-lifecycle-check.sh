#!/usr/bin/env bash
# Prove, against real processes, that the daemon's lifetime is owned.
#
# Five scenarios, and each one is a bug that actually happened:
#
#   1. QUIT      a launch that started a daemon reaps it. Zero juancoded left.
#   2. SIGKILL   a launch that never got to run its trap does not strand one. The
#                daemon notices its owner is gone and ends itself.
#   3. FOREIGN   a daemon somebody else started SURVIVES a launch and a quit. It is
#                holding their ptys; adopting it would be a guess and ending it would
#                be somebody else's work lost.
#   4. LAUNCHD   a daemon the LaunchAgent started is not claimed and not reaped, and a
#                STALE one is warned about rather than restarted. Claiming it would arm
#                the trap, so quitting the app would end a daemon launchd restarts
#                empty: five live agents lost to closing a window.
#   5. PERSIST   JUANCODE_DAEMON_PERSIST=1 starts a daemon that outlives the app, says
#                so in the ownership record, and is STILL there after a second launch
#                quits. This is the one scenario whose failure is silent: the daemon
#                lives or dies by whether the trap armed, and a `started` verdict where
#                `persistent` was asked for arms it.
#
# WHY A SLEEPER INSTEAD OF THE APP. The lifetime is a contract between the launch
# shell, juancoded.sh and juancoded; which binary sits in the foreground is irrelevant
# to it. The real app would need a window server and would fight the running instance
# for :4280, so JUANCODE_APP_BIN puts a sleeper there — through the real dev-app.sh, so
# what is under test is the actual ensure/trap/reap path and not a copy of it.
#
# SAFETY. Its own port and its own data directory, both far from anything real: it can
# neither be adopted by a running app nor write to ~/.juancode. Every signal it sends
# goes to a pid it recorded itself starting. There is no `pkill juancoded` here and
# there must never be one: a name match would also end the daemon belonging to another
# worktree, and that one is holding real ptys.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS/../../.." && pwd)"

# Deliberately not 4290 (the real daemon), 4280 (the app) or 4281 (the sidecar).
export JUANCODED_PORT="${JUANCODED_PORT:-4390}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/juancoded-lifecycle-XXXXXX")"
export JUANCODED_DATA_DIR="$WORK/data"
# Short name on purpose: a unix socket path caps out near 104 bytes.
export JUANCODED_SOCKET="$WORK/jd.sock"
# Pinned, not inherited. The profile is irrelevant to a lifetime contract, and this
# script builds one of them; inheriting a JUANCODE_CONFIG=release from the shell would
# have it launch a binary it never built.
export JUANCODE_CONFIG=debug
# Short enough to watch, long enough that the poll interval is not the thing being
# measured. Production is 120s; see owner.rs for why it is generous there.
export JUANCODE_OWNER_GRACE_SECONDS="${JUANCODE_OWNER_GRACE_SECONDS:-6}"
BIN="$ROOT/apps/juancoded/target/debug/juancoded"

mkdir -p "$JUANCODED_DATA_DIR"
SLEEPER="$WORK/stand-in-app.sh"
cat > "$SLEEPER" <<'APP'
#!/usr/bin/env bash
# Stands in for the juancode app: exists, stays in the foreground, does nothing.
trap 'exit 0' TERM INT
while :; do /bin/sleep 1; done
APP
chmod +x "$SLEEPER"

# Everything this script started, so teardown can be exact rather than by name. The
# trap fires on EVERY exit path, including a failed assertion under `set -e`: the one
# thing worse than a lifecycle bug is a lifecycle test that leaks a daemon.
STARTED_PIDS=()
cleanup() {
  local pid
  for pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  # SIGKILLing a launch reparents its sleeper to launchd, so the recorded pids alone
  # leave one behind — measured, not guessed. This is the one name match here, and it
  # is safe because it is on this run's own mktemp path: it cannot match a juancoded,
  # and it cannot match another run of this script.
  pkill -TERM -f "$SLEEPER" 2>/dev/null || true
  /bin/sleep 0.5
  for pid in "${STARTED_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -9 "$pid" 2>/dev/null || true
  done
  pkill -9 -f "$SLEEPER" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM HUP

FAILURES=0
say()  { printf '\n=== %s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# Only ever daemons on THIS port with THIS data dir. `pgrep -f juancoded` would sweep
# in the real one.
# `|| true` on the lsof, not on the pipeline: lsof exits nonzero when it finds nothing,
# and under `set -o pipefail` that made "the port is now free" — the very thing every
# assertion here waits for — abort the script.
mine() { { lsof -nP -iTCP:"$JUANCODED_PORT" -sTCP:LISTEN -Fp 2>/dev/null || true; } | sed -n 's/^p//p' | sort -u; }
evidence() {
  printf -- '--- ps for :%s ---\n' "$JUANCODED_PORT"
  local pids; pids="$(mine)"
  if [ -z "$pids" ]; then
    printf '(nothing listening on :%s)\n' "$JUANCODED_PORT"
    return
  fi
  ps -o pid=,ppid=,lstart=,command= -p "$(printf '%s' "$pids" | tr '\n' ',' | sed 's/,$//')"
}
# Wait until `mine` is empty, or give up. Returns 1 on give-up.
wait_gone() {
  local limit="$1" waited=0
  while [ -n "$(mine)" ]; do
    [ "$waited" -ge "$((limit * 10))" ] && return 1
    /bin/sleep 0.1
    waited=$((waited + 1))
  done
}

say "building juancoded once, so the scenarios do not each pay for it"
cargo build --manifest-path "$ROOT/apps/juancoded/Cargo.toml" -p juancoded >&2
# Cargo already did the change detection above; re-running it per launch would only add
# seconds. THIS IS A TEST-ONLY SHORTCUT — see juancoded.sh, where skipping the build is
# how you end up running a stale core.
export JUANCODE_SKIP_DAEMON_BUILD=1

launch() {
  JUANCODE_APP_BIN="$SLEEPER" "$SCRIPTS/dev-app.sh" >"$WORK/launch.log" 2>&1 &
  local pid=$!
  STARTED_PIDS+=("$pid")
  local waited=0
  while [ -z "$(mine)" ]; do
    kill -0 "$pid" 2>/dev/null || { cat "$WORK/launch.log"; return 1; }
    [ "$waited" -ge 300 ] && { cat "$WORK/launch.log"; return 1; }
    /bin/sleep 0.1
    waited=$((waited + 1))
  done
  printf '%s' "$pid"
}

# ---------------------------------------------------------------- 1. a normal quit
say "SCENARIO 1: a launch that quits takes its daemon with it"
LAUNCH="$(launch)" || { fail "scenario 1: the launch never brought a daemon up"; exit 1; }
DAEMON="$(mine)"
evidence
# Quitting the app is the app process exiting; the launch shell then runs its trap.
pkill -TERM -P "$LAUNCH" -f stand-in-app 2>/dev/null || kill -TERM "$LAUNCH"
if wait_gone 20; then pass "no daemon left after the quit"; else fail "daemon $DAEMON survived the quit"; fi
evidence

# ------------------------------------------------------- 2. a launch that is SIGKILLed
say "SCENARIO 2: a SIGKILLed launch cannot run a trap, so the daemon ends itself"
LAUNCH="$(launch)" || { fail "scenario 2: the launch never brought a daemon up"; exit 1; }
DAEMON="$(mine)"
evidence
# SIGKILL the launch shell itself. No trap runs; nothing on this side will ever reap.
kill -9 "$LAUNCH" 2>/dev/null || true
/bin/sleep 1
printf -- '--- the launch is gone; the daemon is briefly an orphan ---\n'
evidence
# The grace period plus the poll interval plus room for the shutdown itself.
if wait_gone $((JUANCODE_OWNER_GRACE_SECONDS + 15)); then
  pass "the daemon self-exited within the grace period"
else
  fail "daemon $DAEMON is still running: it outlived a launch that was SIGKILLed"
fi
evidence

# ------------------------------------------------------------ 3. somebody else's daemon
say "SCENARIO 3: a daemon this launch did not start is left strictly alone"
# Started with no owner in its environment and no ownership record: exactly the shape of
# `cargo run -p juancoded` in another terminal.
"$BIN" >"$WORK/foreign.log" 2>&1 &
FOREIGN=$!
STARTED_PIDS+=("$FOREIGN")
waited=0
while [ -z "$(mine)" ]; do
  [ "$waited" -ge 300 ] && { fail "scenario 3: the stand-in foreign daemon never bound"; exit 1; }
  /bin/sleep 0.1
  waited=$((waited + 1))
done
evidence
LAUNCH="$(JUANCODE_APP_BIN="$SLEEPER" "$SCRIPTS/dev-app.sh" >"$WORK/launch3.log" 2>&1 & echo $!)"
STARTED_PIDS+=("$LAUNCH")
/bin/sleep 3
grep -q 'FOREIGN' "$WORK/launch3.log" \
  && pass "the launch reported it, loudly, instead of adopting it" \
  || fail "the launch said nothing about the foreign daemon"
pkill -TERM -P "$LAUNCH" -f stand-in-app 2>/dev/null || kill -TERM "$LAUNCH" 2>/dev/null || true
/bin/sleep 3
if kill -0 "$FOREIGN" 2>/dev/null; then
  pass "the foreign daemon survived a launch and a quit"
else
  fail "the foreign daemon was ended by a launch that did not start it"
fi
evidence
# And it must still be there after the grace period: no owner was ever declared for it,
# so its watchdog must be inert rather than counting down.
/bin/sleep $((JUANCODE_OWNER_GRACE_SECONDS + 4))
if kill -0 "$FOREIGN" 2>/dev/null; then
  pass "an unowned daemon does not self-exit: the watchdog is opt-in"
else
  fail "an unowned daemon ended itself — nothing ever claimed it"
fi
evidence

# ------------------------------------------------------------- 4. launchd's daemon
say "SCENARIO 4: a launchd-managed daemon is neither claimed nor reaped, even when stale"
# The shape `juancoded.sh serve` leaves behind: a daemon with a `managed=launchd`
# ownership record. Written by hand here rather than by actually installing the
# LaunchAgent, because installing one would touch the developer's real
# ~/Library/LaunchAgents and their real daemon; what is under test is the DECISION the
# launch makes about such a record, which is all in juancoded.sh.
#
# This is the scenario that costs the most if it regresses. A launch that claimed this
# daemon would arm the trap in dev-app.sh, so quitting the app would end a daemon
# launchd then restarts EMPTY — every live agent gone because somebody closed a window.
kill -TERM "$FOREIGN" 2>/dev/null || true
wait_gone 20 || { fail "scenario 4: could not free :$JUANCODED_PORT"; exit 1; }
"$BIN" >"$WORK/launchd.log" 2>&1 &
MANAGED=$!
STARTED_PIDS+=("$MANAGED")
waited=0
while [ -z "$(mine)" ]; do
  [ "$waited" -ge 300 ] && { fail "scenario 4: the stand-in launchd daemon never bound"; exit 1; }
  /bin/sleep 0.1
  waited=$((waited + 1))
done
# `owner_pid=1` is what `serve` writes, and juancoded's own watchdog drops owners <= 1.
{
  printf 'daemon_pid=%s\n' "$MANAGED"
  printf 'token=com.juanone.juancoded\n'
  printf 'owner_pid=1\n'
  printf 'managed=launchd\n'
} > "$JUANCODED_DATA_DIR/juancoded.owner"
# And make it STALE, so what is exercised is the build-mismatch path specifically: the
# one where a supervisor might be tempted to "helpfully" restart.
sed -i '' 's/^build_id=.*/build_id=an-older-build/' "$JUANCODED_DATA_DIR/juancoded.run"
evidence
VERDICT="$("$SCRIPTS/juancoded.sh" ensure "lifecycle-$$" "$$" 2>"$WORK/launchd-ensure.log")"
sed 's/^/    /' "$WORK/launchd-ensure.log"
case "$VERDICT" in
  launchd*) pass "ensure reported \`$VERDICT\` — not claimed" ;;
  *)        fail "ensure reported \`$VERDICT\`; a launchd-managed daemon must report launchd" ;;
esac
grep -q 'STALE' "$WORK/launchd-ensure.log" \
  && pass "it said the daemon is stale" \
  || fail "a stale launchd daemon was not reported as stale"
# The ownership record must still say launchd: a claim would have overwritten it.
[ "$(sed -n 's/^managed=//p' "$JUANCODED_DATA_DIR/juancoded.owner")" = "launchd" ] \
  && pass "the ownership record still names launchd" \
  || fail "the launch overwrote launchd's ownership record"
# And the explicit reap — the thing the app's exit runs — must refuse.
"$SCRIPTS/juancoded.sh" reap "lifecycle-$$" >>"$WORK/launchd-ensure.log" 2>&1 || true
/bin/sleep 2
if kill -0 "$MANAGED" 2>/dev/null; then
  pass "a reap left it running"
else
  fail "the reap ended a launchd-managed daemon"
fi
evidence

# ------------------------------------------------------- 5. the stated persistent mode
say "SCENARIO 5: JUANCODE_DAEMON_PERSIST=1 outlives the app, twice, and says it meant to"
kill -TERM "$MANAGED" 2>/dev/null || true
wait_gone 20 || { fail "scenario 5: could not free :$JUANCODED_PORT"; exit 1; }
rm -f "$JUANCODED_DATA_DIR/juancoded.owner" "$JUANCODED_DATA_DIR/juancoded.run"

# `launch`, with the mode asked for. Same script, same seam; the only difference is the
# env var, which is the whole claim being tested.
launch_persist() {
  local persist="$1" log="$2"
  JUANCODE_DAEMON_PERSIST="$persist" JUANCODE_APP_BIN="$SLEEPER" "$SCRIPTS/dev-app.sh" \
    >"$WORK/$log" 2>&1 &
  local pid=$!
  STARTED_PIDS+=("$pid")
  local waited=0
  while [ -z "$(mine)" ]; do
    kill -0 "$pid" 2>/dev/null || { cat "$WORK/$log"; return 1; }
    [ "$waited" -ge 300 ] && { cat "$WORK/$log"; return 1; }
    /bin/sleep 0.1
    waited=$((waited + 1))
  done
  printf '%s' "$pid"
}
quit_launch() {
  pkill -TERM -P "$1" -f stand-in-app 2>/dev/null || kill -TERM "$1" 2>/dev/null || true
}
# Wait for a line to appear in a launch log, rather than reading it straight away.
# `launch` returns as soon as the port answers, and when the daemon is ALREADY
# listening — which is the entire point of the launches below — the port answers before
# `dev-app.sh` has even called `ensure`. Grepping the log at that moment reads an empty
# file and reports a launch that said nothing. Measured: it is the difference between
# scenario 5's third launch passing and failing.
wait_log() {
  local file="$1" pattern="$2" waited=0
  while ! grep -q "$pattern" "$file" 2>/dev/null; do
    [ "$waited" -ge 100 ] && return 1
    /bin/sleep 0.1
    waited=$((waited + 1))
  done
}

LAUNCH="$(launch_persist 1 launch5.log)" || { fail "scenario 5: the persistent launch never brought a daemon up"; exit 1; }
PERSISTENT="$(mine)"
evidence
wait_log "$WORK/launch5.log" 'PERSISTENT' \
  && pass "the launch said the daemon is persistent" \
  || fail "a persistent launch said nothing about the mode"
[ "$(sed -n 's/^managed=//p' "$JUANCODED_DATA_DIR/juancoded.owner")" = "persistent" ] \
  && pass "the ownership record records the mode" \
  || fail "the ownership record does not say managed=persistent"
# The reason, not only the fact. `status` reads these back, and an empty intent is how
# a stated mode decays into an unowned one nobody can tell apart.
[ "$(sed -n 's/^intent=//p' "$JUANCODED_DATA_DIR/juancoded.owner")" = "outlives-the-app" ] \
  && pass "and why" \
  || fail "the ownership record does not record the intent"
"$SCRIPTS/juancoded.sh" status 2>&1 | tee "$WORK/status5.log" | sed 's/^/    /'
grep -q 'SURVIVES app quits' "$WORK/status5.log" \
  && pass "status names the mode instead of a stale record" \
  || fail "status did not name the persistent mode"

quit_launch "$LAUNCH"
/bin/sleep 3
if kill -0 "$PERSISTENT" 2>/dev/null; then
  pass "the daemon survived the first quit"
else
  fail "a persistent daemon was reaped by the launch that started it"
fi

# The second launch is the whole ticket: it must CONNECT to that daemon, not claim it.
# A claim here arms the trap in dev-app.sh, and the next quit ends the sessions the mode
# exists to keep.
LAUNCH="$(launch_persist 1 launch5b.log)" || { fail "scenario 5: the second launch failed"; exit 1; }
wait_log "$WORK/launch5b.log" 'PERSISTENT' \
  && pass "the second launch reported the mode it connected to" \
  || fail "the second launch said nothing about the persistent daemon"
[ "$(mine)" = "$PERSISTENT" ] \
  && pass "the second launch reused the same daemon" \
  || fail "the second launch replaced the persistent daemon (now $(mine), was $PERSISTENT)"
[ "$(sed -n 's/^managed=//p' "$JUANCODED_DATA_DIR/juancoded.owner")" = "persistent" ] \
  && pass "and did not claim it" \
  || fail "the second launch claimed a persistent daemon"
quit_launch "$LAUNCH"
/bin/sleep 3
if kill -0 "$PERSISTENT" 2>/dev/null; then
  pass "and it is still running after the second quit"
else
  fail "the persistent daemon died on the second quit"
fi

# A DEFAULT launch meeting it must leave it alone too. Otherwise the mode lasts exactly
# as long as nobody forgets the env var, which is not a mode.
LAUNCH="$(launch_persist 0 launch5c.log)" || { fail "scenario 5: the default launch failed"; exit 1; }
wait_log "$WORK/launch5c.log" 'PERSISTENT' \
  && pass "a default launch reported the persistent daemon" \
  || fail "a default launch said nothing about the persistent daemon it connected to"
quit_launch "$LAUNCH"
/bin/sleep 3
if kill -0 "$PERSISTENT" 2>/dev/null; then
  pass "a default launch's quit did not reap it"
else
  fail "a default launch reaped a persistent daemon"
fi
# And the watchdog must be inert: no owner was ever declared, so nothing counts down.
/bin/sleep $((JUANCODE_OWNER_GRACE_SECONDS + 4))
if kill -0 "$PERSISTENT" 2>/dev/null; then
  pass "the self-exit watchdog never armed for it"
else
  fail "a persistent daemon self-exited — its watchdog was armed"
fi
evidence
kill -TERM "$PERSISTENT" 2>/dev/null || true
wait_gone 20 || true

say "RESULT"
if [ "$FAILURES" -eq 0 ]; then
  printf 'all five scenarios hold\n'
else
  printf '%s check(s) failed\n' "$FAILURES"
fi
exit "$FAILURES"
