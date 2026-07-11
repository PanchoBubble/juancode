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

if [ "$PRINT_BIN" = "1" ]; then
  echo "$APP/Contents/MacOS/juancode"
else
  exec "$APP/Contents/MacOS/juancode" "$@"
fi
