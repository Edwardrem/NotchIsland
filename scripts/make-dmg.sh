#!/bin/zsh
# Builds NotchIsland.app (release, Apple silicon) and wraps it in dist/NotchIsland.dmg.
# Usage: scripts/make-dmg.sh [version]   e.g. scripts/make-dmg.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
BUILD="$(date +%Y%m%d%H%M)"
APP="dist/NotchIsland.app"
ROOT="dist/dmg-root"
DMG="dist/NotchIsland.dmg"

echo "▸ swift build -c release"
swift build -c release 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" || true
BIN="$(swift build -c release --show-bin-path)/NotchIsland"
[[ -x "$BIN" ]] || { echo "release binary not found at $BIN"; exit 1; }

echo "▸ assembling $APP ($VERSION, build $BUILD)"
rm -rf "$APP" "$ROOT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchIsland"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ codesign (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP"

echo "▸ building $DMG"
mkdir -p "$ROOT"
cp -R "$APP" "$ROOT/"
ln -s /Applications "$ROOT/Applications"
rm -f "$DMG"
hdiutil create -volname "NotchIsland" -srcfolder "$ROOT" -ov -format UDZO -fs HFS+ -quiet "$DMG"
rm -rf "$ROOT"
echo "✓ $(du -h "$DMG" | cut -f1) $DMG"
