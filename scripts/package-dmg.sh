#!/usr/bin/env bash
# Build ZVON and package it into a drag-to-install .dmg.
#   ./scripts/package-dmg.sh [Release|Debug]
# The XcodeGen project/scheme are named Parley, but PRODUCT_NAME=ZVON so the product is ZVON.app.
# For distribution to OTHER Macs without Gatekeeper warnings you additionally need a Developer ID
# signature + notarization (see the notes printed at the end).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-Release}"
DD="$ROOT/.build/dd"
APP="$DD/Build/Products/$CONFIG/ZVON.app"
DIST="$ROOT/dist"
DMG="$DIST/ZVON.dmg"

echo "▸ xcodegen"
xcodegen generate >/dev/null

echo "▸ build ($CONFIG)"
xcodebuild -project Parley.xcodeproj -scheme Parley -configuration "$CONFIG" \
  -derivedDataPath "$DD" build >/dev/null

[ -d "$APP" ] || { echo "✗ app not found: $APP"; exit 1; }

echo "▸ stage"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/ZVON.app"
ln -s /Applications "$STAGE/Applications"

echo "▸ dmg"
rm -f "$DMG"
hdiutil create -volname "ZVON" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
echo
echo "This DMG is self-signed. On another Mac it opens via right-click → «Открыть»."
echo "For clean distribution (no warning): sign with a Developer ID cert, then notarize:"
echo "  codesign --deep --force --options runtime --sign \"Developer ID Application: NAME (TEAMID)\" \"$APP\""
echo "  xcrun notarytool submit \"$DMG\" --apple-id you@mail --team-id TEAMID --password APP_PW --wait"
echo "  xcrun stapler staple \"$DMG\""
