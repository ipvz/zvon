#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -O -parse-as-library -swift-version 5 Sources/Features/CodexUsage/*.swift Sources/UI/L11n.swift Tests/CodexUsageTests.swift -o "$TEST_DIR/codex-usage-tests"
"$TEST_DIR/codex-usage-tests"
