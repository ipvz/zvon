#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library Sources/Model/PipelineTypes.swift \
  Sources/Model/MeetingAudioRecorder.swift Tests/AudioRecorderTests.swift -o "$TEST_DIR/recorder-tests"
"$TEST_DIR/recorder-tests"
