#!/bin/zsh
# Builds NotchIsland.app (release, Apple silicon) and wraps it in dist/NotchIsland.dmg.
# Usage: scripts/make-dmg.sh [version]   e.g. scripts/make-dmg.sh 1.1.0
#
# Signing, best available first:
#   1. A "Developer ID Application" identity in the login keychain (paid Apple Developer Program):
#      hardened runtime + timestamp, and with NOTARY_PROFILE=<notarytool keychain profile> the app and
#      the DMG are notarized and stapled, so Gatekeeper opens them without the "could not verify" dialog.
#   2. The project's self-signed "NotchIsland Developer" identity (scripts/signing-identity.sh):
#      stable across builds so permission grants survive updates; Gatekeeper still asks on first launch.
#   3. Ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.1.0}"
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

echo "▸ codesign"
ENTITLEMENTS="Resources/NotchIsland.entitlements"
DEVID="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
NOTARIZE=0
if [[ -n "$DEVID" ]]; then
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$APP"
  echo "  signed with \"$DEVID\" (hardened runtime)"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARIZE=1
    echo "▸ notarizing $APP (profile $NOTARY_PROFILE)"
    ditto -c -k --keepParent "$APP" dist/NotchIsland-notarize.zip
    xcrun notarytool submit dist/NotchIsland-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f dist/NotchIsland-notarize.zip
    xcrun stapler staple "$APP"
  else
    echo "  NOTARY_PROFILE not set, skipping notarization (README ▸ Notarized builds)"
  fi
elif KEYCHAIN="$(scripts/signing-identity.sh --unlock 2>/dev/null)"; then
  codesign --force --deep --sign "NotchIsland Developer" --keychain "$KEYCHAIN" "$APP"
  echo "  signed with \"NotchIsland Developer\" (stable identity, permission grants survive updates)"
else
  codesign --force --deep --sign - "$APP"
  echo "  signed ad-hoc; run scripts/signing-identity.sh first for a stable identity"
fi
codesign --verify --verbose=1 "$APP"
codesign -dr - "$APP" 2>&1 | grep designated

echo "▸ building $DMG"
mkdir -p "$ROOT"
cp -R "$APP" "$ROOT/"
ln -s /Applications "$ROOT/Applications"
cp Resources/dmg-readme.txt "$ROOT/Read me first.txt"
rm -f "$DMG"
hdiutil create -volname "NotchIsland" -srcfolder "$ROOT" -ov -format UDZO -fs HFS+ -quiet "$DMG"
rm -rf "$ROOT"
if [[ "$NOTARIZE" == 1 ]]; then
  echo "▸ notarizing $DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
echo "✓ $(du -h "$DMG" | cut -f1) $DMG"
