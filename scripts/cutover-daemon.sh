#!/usr/bin/env bash
# Move the live juancoded onto main, and carry the mirror-only history into its store.
#
# Two things are wrong with the running setup and this fixes both in one pass:
#
#   1. The launchd daemon is pinned to whichever directory last ran
#      `juancoded-agent.sh install`. It has been serving an unmerged branch, so the
#      app on top of it has been running week-old code.
#   2. 27 sessions have scrollback in the desktop mirror that the daemon store has
#      nothing for. juancode-52e8.14.4 removed the merge that used to paper over
#      that, so those sessions are searchable by title only until the import runs.
#
# THIS KILLS EVERY LIVE SESSION. The daemon owns the ptys; stopping it ends the
# agents inside it, including the one you may be reading this from. The script lists
# what will die and asks first. `--yes` skips the question.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT="$ROOT/apps/native/scripts/juancoded-agent.sh"
BIN="$ROOT/apps/juancoded/target/release/juancoded"
MIRROR="$HOME/.juancode/data/juancode-rust.db"
RELAY_URL="${JUANCODE_RELAY_URL:-http://127.0.0.1:4280}"

ASSUME_YES=0
[[ ${1:-} == --yes || ${1:-} == -y ]] && ASSUME_YES=1

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31mcutover: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 0. Refuse to run from a worktree ------------------------------------------
# `install` re-pins the plist to the directory it runs from, which is exactly how
# the daemon ended up on a branch. Reinstalling from a worktree would repeat it.
say "Checking this is the main checkout"
[[ -f "$ROOT/.git" ]] && die "$ROOT is a worktree (.git is a file). Run this from the main checkout."
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
[[ $BRANCH == main ]] || die "on branch '$BRANCH', not main. The daemon should serve main."
git -C "$ROOT" fetch -q origin
LOCAL="$(git -C "$ROOT" rev-parse HEAD)"
REMOTE="$(git -C "$ROOT" rev-parse origin/main)"
[[ $LOCAL == "$REMOTE" ]] || die "main is not level with origin/main. Pull or push first."
echo "main at $(git -C "$ROOT" log --oneline -1)"

[[ -f $MIRROR ]] || die "no mirror at $MIRROR — nothing to import."

# --- 1. Say what dies ----------------------------------------------------------
say "Live sessions (all of these end)"
curl -s -m 5 "$RELAY_URL/api/sessions" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("  (could not read the session list — the daemon may already be down)"); raise SystemExit
rows = d if isinstance(d, list) else d.get("sessions", [])
live = [r for r in rows if r.get("status") == "running"]
if not live:
    print("  none")
for r in live:
    print(f"  {r.get(chr(105)+chr(100),chr(63)*8)[:8]}  {(r.get('"'"'title'"'"') or '"'"''"'"')[:64]}")
' || echo "  (daemon not answering)"

if [[ $ASSUME_YES -eq 0 ]]; then
  printf '\nStop the daemon and kill those sessions? [y/N] '
  read -r reply </dev/tty
  [[ $reply == y || $reply == Y ]] || die "nothing done."
fi

# --- 2. Quit the app before the daemon ------------------------------------------
# Order matters: CoreBoot falls back to the SWIFT core when the daemon does not
# answer the handshake, so an app left running while the daemon is down comes back
# on the wrong core with a different database.
say "Quitting juancode.app (if it is running)"
osascript -e 'tell application "juancode" to quit' 2>/dev/null || echo "not running"

# --- 3. Stop the daemon ---------------------------------------------------------
# There are four ownership states and only one of them answers to launchd. The
# first pass through this script died here: the launchd job was "loaded but not
# running" (so `agent.sh stop` had nothing to do) while an UNOWNED daemon — one
# started outside any script, which nothing on disk claims and no watchdog reaps —
# held the store anyway. So stop the job, then deal with whatever is still there.
#
# The plist is KeepAlive{SuccessfulExit=false}: a clean stop stays stopped, only a
# crash comes back. import-swift refuses while anything holds the store.
# NOT pgrep. On this machine `pgrep -f juancoded` returns nothing while the daemon is
# plainly running (`ps` shows it, `pgrep -af` finds it) — so a pgrep-based guard reports
# "daemon down" and lets the import run straight into a held store. Match the command
# path's last component with ps instead, which was verified against the live process.
daemon_pids() { ps -Ao pid=,command= | awk '$2 ~ /juancoded$/ {print $1}'; }

say "Stopping the launchd daemon"
"$AGENT" stop || true

for _ in $(seq 1 20); do [[ -z $(daemon_pids) ]] && break; sleep 0.5; done

# SIGTERM takes juancoded through its orderly shutdown (it flushes scrollback and
# exits 0), which is why this is a TERM and not a KILL. juancoded.sh's own `stop`
# is not used here: it prompts, and it only knows a daemon some launch claimed.
if [[ -n $(daemon_pids) ]]; then
  say "An unowned juancoded is still holding the store — ending it"
  for pid in $(daemon_pids); do
    echo "  SIGTERM $pid ($(ps -o command= -p "$pid" 2>/dev/null | head -c 70))"
    kill -TERM "$pid" 2>/dev/null || true
  done
  for _ in $(seq 1 40); do [[ -z $(daemon_pids) ]] && break; sleep 0.5; done
fi

[[ -n $(daemon_pids) ]] && die "juancoded still running as PID(s) $(daemon_pids | tr '\n' ' ')— stop it by hand."
echo "daemon down"

# --- 4. Build from main ---------------------------------------------------------
# Per-crate, never `cargo fmt --all` / workspace-wide: apps/juancoded is not
# rustfmt-clean and has no CI fmt gate.
say "Building juancoded from main (release)"
( cd "$ROOT/apps/juancoded" && cargo build --release -p juancoded )
[[ -x $BIN ]] || die "no binary at $BIN after the build."

# --- 5. Import the mirror-only history ------------------------------------------
# Additive and idempotent: a second run reports there is nothing to do. Source is
# the desktop MIRROR, not ~/.juancode/data/juancode.db (the old Swift core store).
say "Importing mirror-only history into the daemon store"
"$BIN" import-swift "$MIRROR"

# --- 6. Reinstall the job, pinned here -------------------------------------------
# `install` refuses to repoint a plist that names a different checkout without an
# interactive y/N — and on the first run that prompt ate a stray buffered newline and
# answered itself "no", leaving the agent pinned to the old worktree after everything
# else had succeeded. Remove the old plist first: with no prior installation there is
# nothing to confirm, so the repoint cannot be lost to a keystroke. `uninstall` only
# prompts when the JOB is running, and by here it is not.
say "Removing the old launchd job"
while read -r -t 0.05 -n 4096 _ </dev/tty 2>/dev/null; do :; done   # drain buffered keys
"$AGENT" uninstall </dev/tty || true

say "Installing the launchd job from $ROOT"
"$AGENT" install </dev/tty

# --- 7. Show what is actually serving now ----------------------------------------
say "Result"
for _ in $(seq 1 40); do
  curl -s -m 2 "$RELAY_URL/api/health" >/dev/null 2>&1 && break
  sleep 0.5
done
"$AGENT" status || true
echo
echo "daemon source: $ROOT @ $(git -C "$ROOT" rev-parse --short HEAD)"

# The plist is the thing that actually decides what starts at your next login, and
# it is pinned at install time. A stale WorkingDirectory here is the whole bug this
# script exists for, so assert it rather than trusting that `install` did its job.
PINNED="$(python3 -c '
import plistlib, pathlib
p = plistlib.loads(pathlib.Path.home().joinpath("Library/LaunchAgents/com.juanone.juancoded.plist").read_bytes())
print(p.get("WorkingDirectory", ""))
' 2>/dev/null || echo '?')"
echo "plist pinned to: $PINNED"
[[ $PINNED == "$ROOT" ]] || die "plist still points at '$PINNED', not $ROOT — next login would start the wrong daemon."
echo
echo "Relaunch the app with: open $ROOT/apps/native/.build/juancode.app"
echo "(build it first if it is stale: swift build -c release --package-path $ROOT/apps/native"
echo " && $ROOT/scripts/bundle-app.sh release)"
