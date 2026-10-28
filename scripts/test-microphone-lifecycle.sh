#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -c Sources/Util/ExceptionCatcher.m -o "$TEST_DIR/catcher.o"
xcrun swiftc -parse-as-library -import-objc-header Sources/Util/ExceptionCatcher.h \
  Sources/Model/LiveAudioSource.swift Tests/MicrophoneLifecycleTests.swift "$TEST_DIR/catcher.o" -o "$TEST_DIR/mic-tests"
"$TEST_DIR/mic-tests"
if [[ "${MIC_NATIVE_SMOKE:-0}" == "1" ]]; then
  "$TEST_DIR/mic-tests" --native
fi
