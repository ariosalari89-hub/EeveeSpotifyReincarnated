#!/bin/bash
set -euo pipefail
CONTROL_QA_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/spicy-controls-qa.XXXXXX")
for source in Sources/EeveeSpotifyC/SpicyLyricsNativeControls.m Tests/SpicyLyricsNativeControls/main.m; do
  xcrun clang -fobjc-arc -fblocks -c -ISources/EeveeSpotifyC/include \
    "$source" -o "$CONTROL_QA_DIR/$(basename "$source" .m).o"
done
xcrun swiftc -swift-version 5 -parse-as-library \
  Tests/SpicyLyricsNativeControls/SwiftSmartShuffle.swift \
  "$CONTROL_QA_DIR/SpicyLyricsNativeControls.o" "$CONTROL_QA_DIR/main.o" \
  -framework Foundation -o "$CONTROL_QA_DIR/spicy-native-controls-tests"
"$CONTROL_QA_DIR/spicy-native-controls-tests"
