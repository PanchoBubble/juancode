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
CORE_URL="${JUANCODE_CORE_URL:-http://127.0.0.1:4280}"

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
curl -s -m 5 "$CORE_URL/api/sessions" 2>/dev/null | python3 -c '
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
# The plist is KeepAlive{SuccessfulExit=false}: a clean stop stays stopped, only a
# crash comes back. import-swift refuses while anything holds the store.
say "Stopping the launchd daemon"
"$AGENT" stop || true
for _ in $(seq 1 30); do
  pgrep -qf '[j]uancoded( |$)' || break
  sleep 0.5
done
pgrep -qf '[j]uancoded( |$)' && die "juancoded is still running; stop it by hand before importing."
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
say "Reinstalling the launchd job from $ROOT"
"$AGENT" install

# --- 7. Show what is actually serving now ----------------------------------------
say "Result"
for _ in $(seq 1 40); do
  curl -s -m 2 "$CORE_URL/api/health" >/dev/null 2>&1 && break
  sleep 0.5
done
"$AGENT" status || true
echo
echo "daemon source: $ROOT @ $(git -C "$ROOT" rev-parse --short HEAD)"
echo
echo "Relaunch the app with: open $ROOT/apps/native/.build/juancode.app"
echo "(build it first if it is stale: swift build -c release --package-path $ROOT/apps/native"
echo " && $ROOT/scripts/bundle-app.sh release)"
