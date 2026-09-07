#!/bin/bash
set -euo pipefail
QA_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/local-audio-tests.XXXXXX")
xcrun swiftc -swift-version 5 -framework AVFoundation -framework ImageIO \
  Sources/EeveeSpotify/LocalFiles/LocalAudioImporter.swift \
  Sources/EeveeSpotify/LocalFiles/LocalAudioLibrary.swift \
  Sources/EeveeSpotify/LocalFiles/LocalAudioArtworkReader.swift \
  Sources/EeveeSpotify/LocalFiles/LocalAudioArtworkService.swift \
  Sources/EeveeSpotify/LocalFiles/LocalAudioArtworkDiagnostics.swift \
  Tests/LocalAudioImport/main.swift Tests/LocalAudioImport/LibraryChecks.swift \
  Tests/LocalAudioImport/ArtworkChecks.swift Tests/LocalAudioImport/ArtworkServiceChecks.swift \
  Tests/LocalAudioImport/DiagnosticExportChecks.swift -o "$QA_DIR/local-audio-tests"
"$QA_DIR/local-audio-tests" 2>&1 | tee "${RUNNER_TEMP:-/tmp}/local-audio-result.txt"
xcrun clang -fobjc-arc -ISources/EeveeSpotifyC/include -c \
  Sources/EeveeSpotifyC/LocalAudioNativeArtwork.m -o "$QA_DIR/artwork-adapter.o"
xcrun clang -fobjc-arc -ISources/EeveeSpotifyC/include -c \
  Sources/EeveeSpotifyC/LocalAudioArtworkTrace.m -o "$QA_DIR/artwork-trace.o"
xcrun clang -fobjc-arc -c Tests/LocalAudioNativeArtwork/Fixtures.m -o "$QA_DIR/artwork-fixtures.o"
xcrun clang -fobjc-arc -c Tests/LocalAudioNativeArtwork/DisplayFixtures.m -o "$QA_DIR/artwork-display-fixtures.o"
xcrun swiftc -swift-version 5 -framework AVFoundation -framework ImageIO \
  -ISources/EeveeSpotifyC/include -import-objc-header Tests/LocalAudioNativeArtwork/Fixtures.h \
  Sources/EeveeSpotify/LocalFiles/LocalAudioImporter.swift \
  Sources/EeveeSpotify/LocalFiles/LocalAudioLibrary.swift \
  Sources/EeveeSpotify/LocalFiles/LocalAudioArtworkReader.swift \
  Sources/EeveeSpotify/LocalFiles/LocalAudioArtworkService.swift \
  Sources/EeveeSpotify/LocalFiles/LocalAudioArtworkDiagnostics.swift \
  Tests/LocalAudioNativeArtwork/main.swift Tests/LocalAudioNativeArtwork/BoundaryChecks.swift \
  Tests/LocalAudioNativeArtwork/CoreBoundaryChecks.swift \
  Tests/LocalAudioNativeArtwork/DiagnosticChecks.swift \
  "$QA_DIR/artwork-adapter.o" "$QA_DIR/artwork-trace.o" "$QA_DIR/artwork-fixtures.o" "$QA_DIR/artwork-display-fixtures.o" \
  -o "$QA_DIR/native-artwork-tests"
ARTWORK_DIAGNOSTIC_SAMPLE="${RUNNER_TEMP:-$QA_DIR}/local-audio-artwork-diagnostic.log" \
  "$QA_DIR/native-artwork-tests" 2>&1 | tee -a "${RUNNER_TEMP:-/tmp}/local-audio-result.txt"
xcrun clang -fobjc-arc -DEEVEE_ARTWORK_INVALID_LOAD -c Tests/LocalAudioNativeArtwork/Fixtures.m -o "$QA_DIR/artwork-unsupported-fixtures.o"
xcrun swiftc -swift-version 5 -parse-as-library -ISources/EeveeSpotifyC/include \
  -import-objc-header Tests/LocalAudioNativeArtwork/Fixtures.h Tests/LocalAudioNativeArtwork/Unsupported.swift \
  "$QA_DIR/artwork-adapter.o" "$QA_DIR/artwork-trace.o" "$QA_DIR/artwork-unsupported-fixtures.o" -o "$QA_DIR/native-artwork-unsupported-tests"
"$QA_DIR/native-artwork-unsupported-tests" 2>&1 | tee -a "${RUNNER_TEMP:-/tmp}/local-audio-result.txt"
xcrun clang -fobjc-arc -DEEVEE_ARTWORK_INVALID_REMOTE -c Tests/LocalAudioNativeArtwork/Fixtures.m -o "$QA_DIR/artwork-unsupported-remote.o"
xcrun swiftc -swift-version 5 -parse-as-library -ISources/EeveeSpotifyC/include \
  -import-objc-header Tests/LocalAudioNativeArtwork/Fixtures.h Tests/LocalAudioNativeArtwork/UnsupportedRemote.swift \
  "$QA_DIR/artwork-adapter.o" "$QA_DIR/artwork-trace.o" "$QA_DIR/artwork-unsupported-remote.o" -o "$QA_DIR/native-artwork-unsupported-remote-tests"
"$QA_DIR/native-artwork-unsupported-remote-tests" 2>&1 | tee -a "${RUNNER_TEMP:-/tmp}/local-audio-result.txt"
