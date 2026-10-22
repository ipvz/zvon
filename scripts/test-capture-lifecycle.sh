#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library \
  Sources/Model/PipelineTypes.swift Sources/Model/UtteranceTranscriber.swift \
  Sources/Util/Timeout.swift Tests/TimeoutTests.swift Tests/CaptureLifecycleTests.swift -o "$TEST_DIR/capture-lifecycle-tests"
"$TEST_DIR/capture-lifecycle-tests"
