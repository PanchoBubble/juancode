#!/usr/bin/env bash
# Build a RELEASE juancode.app and package it into a distributable .dmg.
#
# Unsigned distribution: there's no Apple Developer ID, so Gatekeeper will block
# the app on first launch. Recipients do a one-time right-click > Open (or
# `xattr -dr com.apple.quarantine /Applications/juancode.app`). See README.
#
# Build logs go to stderr; the ONLY thing printed on stdout is the final .dmg
# path, so callers can do:  DMG="$(scripts/package-app.sh)"
set -euo pipefail

NATIVE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${JUANCODE_VERSION:-0.0.0}"   # marketing version (CFBundleShortVersionString)
BUILD="${JUANCODE_BUILD:-1}"           # monotonic build number (CFBundleVersion)
DIST="$NATIVE/.build/dist"

swift build --package-path "$NATIVE" --product juancode -c release >&2

BIN="$NATIVE/.build/release/juancode"
APP="$DIST/juancode.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Copy (not symlink) so the running executable's real path is inside the .app —
# bundle detection walks up from the resolved exec path.
cp -f "$BIN" "$APP/Contents/MacOS/juancode"
[ -f "$NATIVE/AppIcon.icns" ] && cp -f "$NATIVE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
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
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign the bundle so it has a stable code identity (arm64 requires at
# least an ad-hoc signature to launch). This is NOT notarization.
codesign --force --deep --sign - "$APP" >&2 || true

DMG="$DIST/juancode-${VERSION}.dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/juancode.app"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target
hdiutil create -volname "juancode ${VERSION}" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >&2
rm -rf "$STAGE"

echo "$DMG"
