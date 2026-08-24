#!/usr/bin/env bash
# Build the juancode app and run it from a minimal .app bundle, in the FOREGROUND
# of the calling terminal.
#
# Why a bundle: a bare SPM executable has no bundle identity, so macOS file panels
# (NSOpenPanel / SwiftUI .fileImporter) hang and the Dock icon is flaky. Wrapping
# the binary in a .app fixes both.
#
# Why run the inner binary directly (not `open`): launching via Finder/`open`
# gives the app launchd's stripped environment, which would break juancode's prime
# directive (claude/codex must load YOUR shell env — PATH, MCP, keys). Exec'ing
# Contents/MacOS/juancode straight from the terminal keeps the full environment
# AND gives the process the bundle identity it needs.
set -euo pipefail

# `--print-bin`: build + assemble the bundle, print the inner binary path on
# stdout (build logs go to stderr), and DON'T exec. Lets a caller launch the app
# in the background while still seeing build output. Default: build + exec.
PRINT_BIN=0
[ "${1:-}" = "--print-bin" ] && { PRINT_BIN=1; shift; }

NATIVE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${JUANCODE_CONFIG:-debug}"
DAEMON="$NATIVE/scripts/juancoded.sh"

# A stand-in for the app, and the seam `daemon-lifecycle-check.sh` drives. The daemon's
# lifetime is a contract between THIS shell, juancoded.sh and juancoded; which binary
# sits in the foreground is irrelevant to it. Testing that contract with the real app
# would need a GUI and would fight the running instance for :4280, so the check runs a
# sleeper here instead — and it runs it through this script, so what is under test is
# the real ensure/trap/reap path rather than a copy of it.
APP_BIN="${JUANCODE_APP_BIN:-}"

# Daemon subcommands, forwarded so the lifetime of the core is reachable from the
# same place you launch the app. See juancoded.sh for why adoption is the default.
case "${1:-}" in
  --daemon-status)  exec "$DAEMON" status ;;
  --stop-daemon)    exec "$DAEMON" stop ;;
  --restart-daemon) exec "$DAEMON" restart ;;
esac

if [ -z "$APP_BIN" ]; then
if [ "$CONFIG" = "release" ]; then
  swift build --package-path "$NATIVE" --product juancode -c release >&2
else
  swift build --package-path "$NATIVE" --product juancode >&2
fi

BIN="$NATIVE/.build/$CONFIG/juancode"
APP="$NATIVE/.build/juancode.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Copy (not symlink) so the running executable's real path is inside the .app —
# the kernel execs the resolved path, and bundle detection walks up from it.
# Stage to a temp name and mv into place: overwriting the inode in place (cp -f)
# while an instance is running invalidates the kernel's signature cache for that
# inode — new execs get SIGKILLed before main and the running app can crash on a
# later page-in. mv relinks the directory entry to a fresh inode instead.
cp "$BIN" "$APP/Contents/MacOS/juancode.new"
mv -f "$APP/Contents/MacOS/juancode.new" "$APP/Contents/MacOS/juancode"
# App icon (regenerate with: swift scripts/make-icon.swift).
[ -f "$NATIVE/AppIcon.icns" ] && cp -f "$NATIVE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>juancode</string>
  <key>CFBundleDisplayName</key><string>juancode</string>
  <key>CFBundleIdentifier</key><string>dev.juancode.app</string>
  <key>CFBundleExecutable</key><string>juancode</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
# Close the "no stand-in binary" block: everything above builds and assembles the real
# .app, and a lifecycle check that only needs a foreground process skips all of it.
APP_BIN="$APP/Contents/MacOS/juancode"
fi

# The core this launch will talk to, before the app opens a socket to it.
#
# On the Swift core this is a no-op — that core is in-process and launches and dies
# with the app. On the Rust core the daemon is a separate process, and nothing used to
# own its lifetime: it drifted to PPID 1 and every later app launch silently
# reconnected to it, whatever build it was and whatever environment it had been
# started with. The app's session list is a mirror of what that daemon reports, so it
# looked authoritative while being hours stale.
#
# `ensure` rebuilds juancoded (cargo no-ops when nothing changed, and a build failure
# fails this launch rather than falling back to the stale binary), then starts a daemon
# THIS launch owns — reaped by the trap below. A daemon somebody else started is
# reported and left strictly alone: ending it would end their ptys.
#
# The cost, stated plainly: live agent sessions no longer survive quitting the app.
# That is the trade for never being able to read a stale mirror.
#
# An empty token under `--print-bin` is not an oversight: that invocation ends the
# moment it prints the path, so it can never reap anything, and claiming ownership it
# cannot honour would arm a trap that fires while the caller is still about to launch
# the app. It starts the daemon UNOWNED — no trap and no watchdog — and says who has to
# stop it.
if [ "$PRINT_BIN" = "1" ]; then LAUNCH_TOKEN=""; else LAUNCH_TOKEN="$$-$RANDOM"; fi
DAEMON_STATE="$("$DAEMON" ensure "$LAUNCH_TOKEN" "$$")"

# Reap only what this launch started or claimed. `reap` re-checks the token, so a
# daemon another launch has taken over in the meantime is left alone.
#
# EXIT covers a normal quit (including Cmd-Q, which is just the app process exiting)
# and any `set -e` abort; INT and TERM cover ctrl-c and a kill; HUP covers the terminal
# window being closed under this shell, which otherwise skips the trap entirely and is
# one of the ways an orphan got made. All of them funnel through one function, because a
# teardown that only some exit paths reach is the orphan this whole change is about.
#
# What no trap can cover is this shell being SIGKILLed, and that is deliberately not
# solved here: the daemon was handed this shell's pid at spawn and ends ITSELF once
# that pid has been gone for JUANCODE_OWNER_GRACE_SECONDS (default 120s). Two layers,
# because each one covers exactly what the other cannot.
reap_daemon() { "$DAEMON" reap "$LAUNCH_TOKEN" || true; }
if [ -n "$LAUNCH_TOKEN" ]; then
  case "$DAEMON_STATE" in
    started*|claimed*) trap reap_daemon EXIT INT TERM HUP ;;
  esac
fi

# The same identity the daemon was stamped with, so the app can prove a match instead
# of inferring one from a file mtime. Read by `AppIdentity.current`.
export JUANCODE_BUILD_ID="${JUANCODE_BUILD_ID:-$("$DAEMON" build-id)}"

if [ "$PRINT_BIN" = "1" ]; then
  # The caller execs the binary itself, so this export does not reach it. Say so:
  # without the stamp the app falls back to comparing the daemon binary's mtime,
  # which still catches a rebuild but cannot prove an exact match.
  echo "juancode: export JUANCODE_BUILD_ID=$JUANCODE_BUILD_ID before launching for exact build matching" >&2
  echo "$APP_BIN"
else
  # Deliberately NOT `exec`: exec replaces this shell, and a trap in a shell that no
  # longer exists never fires. Running the app as a child costs one bash process and
  # is what makes the teardown reachable. Env fidelity is unaffected — a child
  # inherits this shell's environment exactly, which is what the prime directive
  # needs; it is `open`/Finder that would have stripped it.
  "$APP_BIN" "$@"
fi
