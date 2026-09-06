#!/bin/bash
set -euo pipefail
QA_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/local-audio-ios.XXXXXX")
QA_APP="$QA_DIR/LocalAudioQA.app"
mkdir -p "$QA_APP/en.lproj"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-ios17.0-simulator" -sdk "$SDK" \
  -framework UIKit -framework SwiftUI -framework UniformTypeIdentifiers -framework AVFoundation \
  Sources/EeveeSpotify/LocalFiles/*.swift Tests/LocalAudioIOS/*.swift -o "$QA_APP/LocalAudioQA"
cp "layout/Library/Application Support/EeveeSpotify.bundle/en.lproj/Localizable.strings" "$QA_APP/en.lproj/"
cp Tests/LocalAudioImport/Fixtures/synthetic-tone.mp3 "$QA_APP/"
python3 - "$QA_APP/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'CFBundleIdentifier': 'local.eevee.audioqa', 'CFBundleExecutable': 'LocalAudioQA',
        'CFBundleName': 'Local Audio QA', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
        'CFBundleDevelopmentRegion': 'en', 'MinimumOSVersion': '17.0', 'UILaunchScreen': {},
        'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']
    }, output)
PY
codesign --force --sign - "$QA_APP"
DEVICE="${1:-}"
OWN_DEVICE=false
if [ -z "$DEVICE" ]; then
  RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS")]; print(r[-1]["identifier"] if r else "")')
  [ -n "$RUNTIME" ] || { echo "No iOS simulator runtime available" >&2; exit 1; }
  DEVICE=$(xcrun simctl create LocalAudioQA com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$RUNTIME")
  OWN_DEVICE=true
fi
cleanup() {
  if [ "$OWN_DEVICE" = true ]; then
    xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
    xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
if [ "$OWN_DEVICE" = true ]; then
  xcrun simctl boot "$DEVICE"
  xcrun simctl bootstatus "$DEVICE" -b
fi
xcrun simctl install "$DEVICE" "$QA_APP"
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" local.eevee.audioqa data)
# Confirm the cold display channel before app launch. Simulator setup is not
# part of a picker/import deadline.
xcrun simctl io "$DEVICE" screenshot --type=png "$QA_DIR/preflight-screen.png"
xcrun simctl launch "$DEVICE" local.eevee.audioqa
LAST_PROGRESS=""
for iteration in {1..150}; do
  if [ -s "$CONTAINER/Documents/local-audio-ui-progress.txt" ]; then
    PROGRESS=$(cat "$CONTAINER/Documents/local-audio-ui-progress.txt")
    if [ "$PROGRESS" != "$LAST_PROGRESS" ]; then
      printf '%s\n' "$PROGRESS"
      cp "$CONTAINER/Documents/local-audio-ui-progress.txt" "$RUNNER_TEMP/local-audio-ui-progress.txt"
      LAST_PROGRESS="$PROGRESS"
    fi
  fi
  if [ -s "$CONTAINER/Documents/local-audio-ui-result.txt" ]; then
    cp "$CONTAINER/Documents/local-audio-ui-result.txt" "$RUNNER_TEMP/local-audio-ui-result.txt"
    [ ! -f "$CONTAINER/Documents/local-audio-layout.json" ] || cp "$CONTAINER/Documents/local-audio-layout.json" "$RUNNER_TEMP/"
    for CAPTURE in "$CONTAINER/Documents/local-audio-"*.png; do
      [ ! -f "$CAPTURE" ] || cp "$CAPTURE" "$RUNNER_TEMP/$(basename "$CAPTURE")"
    done
    cat "$RUNNER_TEMP/local-audio-ui-result.txt"
    grep -q '^PASS$' "$RUNNER_TEMP/local-audio-ui-result.txt"
    # The app remains on its finished screen. A slow external display service
    # can no longer prevent the next independent UI behavior from being tested.
    xcrun simctl io "$DEVICE" screenshot --type=png "$RUNNER_TEMP/local-audio-screen.png"
    exit
  fi
  sleep 1
done
xcrun simctl spawn "$DEVICE" log show --last 2m --predicate 'process == "LocalAudioQA"' --style compact
echo "Local audio native UI QA timed out" >&2
exit 1
