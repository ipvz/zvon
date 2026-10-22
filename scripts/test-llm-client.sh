#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library Sources/Model/LLMProvider.swift Sources/Model/LLMClient.swift \
  Tests/LLMClientTests.swift -o "$TEST_DIR/llm-tests"
"$TEST_DIR/llm-tests"
