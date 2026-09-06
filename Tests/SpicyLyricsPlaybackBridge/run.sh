#!/bin/bash
set -euo pipefail
METADATA_QA_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/spicy-metadata-qa.XXXXXX")
METADATA_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
METADATA_TARGET="$(uname -m)-apple-ios17.0-simulator"
for source in Sources/EeveeSpotifyC/SpicyLyricsNativeControls.m Tests/SpicyLyricsPlaybackBridge/spotify-command-boundary.m; do
  xcrun clang -target "$METADATA_TARGET" -isysroot "$METADATA_SDK" -fobjc-arc -fblocks \
    -ISources/EeveeSpotifyC/include -c "$source" -o "$METADATA_QA_DIR/$(basename "$source" .m).o"
done
xcrun swiftc -swift-version 5 -target "$METADATA_TARGET" -sdk "$METADATA_SDK" \
  -ISources/EeveeSpotifyC/include -framework UIKit -framework MediaPlayer \
  Sources/EeveeSpotify/Shared/Models/Headers/SPTURL.swift \
  Sources/EeveeSpotify/Lyrics/Models/Headers/SPTPlayerTrack.swift \
  Sources/EeveeSpotify/Lyrics/Models/Headers/StatefulPlayerImplementation.swift \
  Sources/EeveeSpotify/Lyrics/Models/Extensions/SPTPlayerTrack+Extension.swift \
  Sources/EeveeSpotify/Lyrics/SpicyLyricsPlaybackClock.swift \
  Sources/EeveeSpotify/Lyrics/SpicyLyricsAudioAnalysis.swift \
  Sources/EeveeSpotify/Lyrics/SpicyLyricsPlaybackBridge.swift \
  Tests/SpicyLyricsPlaybackBridge/main.swift "$METADATA_QA_DIR/SpicyLyricsNativeControls.o" \
  "$METADATA_QA_DIR/spotify-command-boundary.o" -o "$METADATA_QA_DIR/metadata-tests"
xcrun simctl spawn "$1" "$METADATA_QA_DIR/metadata-tests" | tee "$RUNNER_TEMP/spicy-metadata-qa-result.txt"
