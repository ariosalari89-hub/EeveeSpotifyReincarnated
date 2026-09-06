#!/bin/bash
set -euo pipefail
QA_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/local-audio-tests.XXXXXX")
xcrun swiftc -swift-version 5 -framework AVFoundation \
  Sources/EeveeSpotify/LocalFiles/LocalAudioImporter.swift \
  Sources/EeveeSpotify/LocalFiles/LocalAudioLibrary.swift \
  Tests/LocalAudioImport/main.swift Tests/LocalAudioImport/LibraryChecks.swift -o "$QA_DIR/local-audio-tests"
"$QA_DIR/local-audio-tests" 2>&1 | tee "${RUNNER_TEMP:-/tmp}/local-audio-result.txt"
