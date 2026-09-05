#!/bin/bash
set -euo pipefail
QA_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/spicy-ios-qa.XXXXXX")
QA_APP="$QA_DIR/SpicyLyricsQA.app"
mkdir -p "$QA_APP"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
xcrun swiftc -swift-version 5 -target "$ARCH-apple-ios17.0-simulator" -sdk "$SDK" \
  -framework UIKit -framework WebKit \
  Sources/EeveeSpotify/Lyrics/SpicyLyricsFullscreenHost.swift \
  Sources/EeveeSpotify/Lyrics/SpicyLyricsFullscreenCoordinator.swift \
  Sources/EeveeSpotify/Lyrics/SpicyLyricsEmbeddedSurfaces.swift \
  Sources/EeveeSpotify/Lyrics/SpicyLyricsAvailability.swift \
  Sources/EeveeSpotify/Lyrics/SpicyLyricsPreviewEntry.swift \
  Tests/SpicyLyricsIOS/main.swift -o "$QA_APP/SpicyLyricsQA"
cp -R "layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer" "$QA_APP/"
cp Tests/SpicyLyricsRenderer/browser-fixture.js Tests/SpicyLyricsRenderer/transition-checks.js "$QA_APP/"
# Isolated historical renderer: demonstrate the reported transition defects in
# WebKit before testing the repaired resources. Never included in the .deb/IPA.
mkdir "$QA_APP/SpicyLyricsBefore"
for resource in index.html styles.css renderer.js renderer-model.js; do
  git show "18a0220:layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer/$resource" > "$QA_APP/SpicyLyricsBefore/$resource"
done
python3 - "$QA_APP/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "local.spicylyrics.qa", "CFBundleExecutable": "SpicyLyricsQA",
        "CFBundleName": "Spicy Lyrics QA", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "17.0", "UILaunchScreen": {},
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
    }, output)
PY
codesign --force --sign - "$QA_APP"
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS")]; print(r[-1]["identifier"] if r else "")')
[ -n "$RUNTIME" ] || { echo "No iOS simulator runtime available" >&2; exit 1; }
DEVICE=$(xcrun simctl create SpicyLyricsQA com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$RUNTIME")
QA_VIDEO_PID=""
stop_capture() {
  if [ -n "$QA_VIDEO_PID" ]; then
    kill -INT "$QA_VIDEO_PID" 2>/dev/null || true
    wait "$QA_VIDEO_PID" || true
    QA_VIDEO_PID=""
  fi
}
cleanup() {
  stop_capture
  xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
  xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
bash Tests/SpicyLyricsPlaybackBridge/run.sh "$DEVICE"
xcrun simctl install "$DEVICE" "$QA_APP"
# Resolve the container and initialize the simulator display service before the
# app starts its screenshot handshake. Cold simctl setup can otherwise consume
# the capture allowance while the app has already settled in landscape.
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" local.spicylyrics.qa data)
xcrun simctl io "$DEVICE" screenshot --type=png "$QA_DIR/preflight-screen.png"
xcrun simctl io "$DEVICE" recordVideo --codec=h264 "$RUNNER_TEMP/qa-session.mp4" >"$QA_DIR/video.log" 2>&1 &
QA_VIDEO_PID=$!
xcrun simctl launch "$DEVICE" local.spicylyrics.qa
# Include the conditional 21-second healthy-recovery setup in the suite budget;
# individual app, rotation, close and screenshot assertions keep their deadlines.
# The desktop-parity phases add independent three-surface motion/paint checks;
# only the overall suite budget grows, not any assertion's sampling deadline.
for iteration in {1..200}; do
  if [ -f "$CONTAINER/Documents/qa-screen-ready.txt" ] && [ ! -f "$CONTAINER/Documents/qa-screen-done.txt" ]; then
    xcrun simctl io "$DEVICE" screenshot --type=png "$RUNNER_TEMP/qa-landscape-screen.png"
    touch "$CONTAINER/Documents/qa-screen-done.txt"
  fi
  if [ -f "$CONTAINER/Documents/qa-result.txt" ]; then
    cp "$CONTAINER/Documents/qa-result.txt" "$RUNNER_TEMP/spicy-ios-qa-result.txt"
    for image in "$CONTAINER/Documents/qa-"*.png; do
      [ ! -f "$image" ] || cp "$image" "$RUNNER_TEMP/$(basename "$image")"
    done
    cat "$RUNNER_TEMP/spicy-ios-qa-result.txt"
    grep -q '^PASS$' "$RUNNER_TEMP/spicy-ios-qa-result.txt"
    exit
  fi
  sleep 1
done
xcrun simctl spawn "$DEVICE" log show --last 3m --predicate 'process == "SpicyLyricsQA"' --style compact
echo "iOS QA timed out" >&2
exit 1
