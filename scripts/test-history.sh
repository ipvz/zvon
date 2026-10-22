#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
# Compile the actual value types without the SwiftUI store and its application singleton graph.
awk '/^@MainActor/{exit} {print}' Sources/Model/SessionStore.swift > "$TEST_DIR/SessionRecord.swift"
xcrun swiftc -parse-as-library Sources/Model/SessionDB.swift \
  "$TEST_DIR/SessionRecord.swift" Tests/SessionDBTests.swift -o "$TEST_DIR/history-tests"
"$TEST_DIR/history-tests"
