#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
SOURCES=()
while IFS= read -r path; do SOURCES+=("$path"); done < <(rg --files Modules/Screenshots/Sources -g '*.swift' | sort)
xcrun swiftc -O -whole-module-optimization -parse-as-library -swift-version 5 "${SOURCES[@]}" Tests/ScreenshotTests.swift -o "$TEST_DIR/screenshot-tests"
"$TEST_DIR/screenshot-tests"
# Real layer-backed panels exercise the native AppKit drawing path that bitmap-only
# tests miss. Opt in because this briefly displays synthetic panels on the desktop.
if [[ "${SCREENSHOT_NATIVE_SMOKE:-0}" == "1" ]]; then
  xcrun swiftc -O -whole-module-optimization -parse-as-library -swift-version 5 "${SOURCES[@]}" Tests/ScreenshotOverlaySmokeTests.swift -o "$TEST_DIR/screenshot-overlay-smoke"
  "$TEST_DIR/screenshot-overlay-smoke"
fi
