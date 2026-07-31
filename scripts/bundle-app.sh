#!/usr/bin/env bash
# Wrap the SwiftPM executable in a real juancode.app bundle.
#
# SwiftPM only produces a bare binary. A bundle is what gives the app a Dock icon,
# a stable bundle id (so UserDefaults, notifications and TCC grants stick), and a
# thing you can `open` or drop in /Applications. Called by the Makefile; safe to run
# directly: scripts/bundle-app.sh [debug|release] [output.app]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$ROOT/apps/native"
BUILD="$NATIVE/.build/$CONFIG"
APP="${2:-$NATIVE/.build/juancode.app}"

BIN="$BUILD/juancode"
if [[ ! -x $BIN ]]; then
  echo "bundle-app: no $CONFIG binary at $BIN — run: swift build -c $CONFIG" >&2
  exit 1
fi

VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo dev)"
BUILD_NUM="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/juancode"
# SwiftPM resource bundles resolve relative to the executable (@loader_path), so they
# travel next to the binary rather than in Contents/Resources.
for b in "$BUILD"/*.bundle; do
  [[ -e $b ]] && cp -R "$b" "$APP/Contents/MacOS/" || true
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>juancode</string>
  <key>CFBundleDisplayName</key><string>juancode</string>
  <key>CFBundleExecutable</key><string>juancode</string>
  <key>CFBundleIdentifier</key><string>com.juanone.juancode</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for a local build to launch and to hold onto the
# permission grants macOS keys off the bundle id.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
  || echo "bundle-app: ad-hoc codesign failed (the app still runs)" >&2

echo "bundle-app: $APP ($CONFIG, $VERSION)"
