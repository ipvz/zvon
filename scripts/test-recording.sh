#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/recording-tests
xcrun swiftc -O -parse-as-library -swift-version 5 \
  Modules/ScreenRecording/Sources/RecordingTimeline.swift \
  Modules/ScreenRecording/Sources/RecordingFiles.swift \
  Modules/ScreenRecording/Sources/RecordingWriter.swift \
  Tests/RecordingTests.swift -o .build/recording-tests/tests
.build/recording-tests/tests "$PWD/.build/recording-tests"
