import pathlib
import shutil
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer"

index = (BUNDLE / "index.html").read_text(encoding="utf-8")
model = (BUNDLE / "renderer-model.js").read_text(encoding="utf-8")
renderer = (BUNDLE / "renderer.js").read_text(encoding="utf-8")
styles = (BUNDLE / "styles.css").read_text(encoding="utf-8")
bridge = (
    ROOT / "Sources/EeveeSpotify/Lyrics/SpicyLyricsPlaybackBridge.swift"
).read_text(encoding="utf-8")
clock = (
    ROOT / "Sources/EeveeSpotify/Lyrics/SpicyLyricsPlaybackClock.swift"
).read_text(encoding="utf-8")
host = (
    ROOT / "Sources/EeveeSpotify/Lyrics/SpicyLyricsFullscreenHost.swift"
).read_text(encoding="utf-8")
repository = (
    ROOT / "Sources/EeveeSpotify/Lyrics/Repositories/SpicyLyricsRepository.swift"
).read_text(encoding="utf-8")
c_header = (
    ROOT / "Sources/EeveeSpotifyC/include/Tweak.h"
).read_text(encoding="utf-8")

# The native host and both renderer assets must use one explicit contract.
assert 'src="renderer-model.js?v=4"' in index
assert 'src="renderer.js?v=4"' in index
assert 'href="styles.css?v=4"' in index
assert "const RENDERER_PROTOCOL_VERSION = 4" in renderer
assert "private static let rendererProtocolVersion = 4" in host
assert 'post("ready", { rendererProtocolVersion: RENDERER_PROTOCOL_VERSION })' in renderer

# No preview-only content may ship in the production bundle.
assert "preview-fixture" not in index
assert "SPICY_PREVIEW_LYRICS" not in renderer
assert not (BUNDLE / "preview-fixture.js").exists()
assert not (BUNDLE / "preview-cover.svg").exists()

# Full-screen transport order and semantics are stable and accessible.
transport_ids = [
    'id="shuffle-button"',
    'id="previous-button"',
    'id="play-button"',
    'id="next-button"',
    'id="repeat-button"',
]
positions = [index.index(item) for item in transport_ids]
assert positions == sorted(positions)
assert 'aria-label="Turn shuffle on"' in index
assert 'aria-label="Turn repeat on"' in index
assert 'class="repeat-one"' in index
assert "min-height: 44px" in styles or "width: 44px; height: 44px" in styles
assert "button:focus-visible" in styles
assert "toggleShuffle" in renderer and "cycleRepeat" in renderer
assert 'case "toggleShuffle"' in bridge and 'case "cycleRepeat"' in bridge
assert 'case "togglePlay", "play", "pause", "toggleShuffle", "cycleRepeat"' in host

# One generation/sequence contract protects rapid skips and stale lyric fetches.
assert 'generation: state.generation' in renderer
assert "model.shouldAcceptPlayback" in renderer
assert "state.lyricsGeneration" in renderer
assert "payload.generation !== state.generation" in renderer
assert "activeGeneration" in host
assert "self.activeGeneration == requestedGeneration" in host
assert '"generation": requestedGeneration' in host
assert '"generation": String(snapshot.generation)' in bridge
assert '"sequence": String(snapshot.sequence)' in bridge

# Playback truth comes from the synchronous stateful player position getter.
assert 'safeDoubleGetter($0, key: "position")' in bridge
assert "source: .statefulPlayer" in bridge
assert "source: .nowPlayingFallback" in bridge
assert "higherAuthorityFreshnessSeconds" in bridge
assert "SpicyLyricsPlaybackSampleSource" in clock
assert "sample.source == .statefulPlayer" in clock
assert "sample.source.rawValue" in clock
assert "sample.generation == generation" in clock
assert "requestSeek(" in clock
assert "pendingSeekTargetSeconds" in clock
assert "requestedPlaybackState" not in bridge
assert "reconcilePlaybackState" not in bridge
assert "setLocalPlaying" not in renderer
assert "state.playback.positionMs = state.dragPosition" not in renderer
assert "model.interpolatedPosition" in renderer
assert 'case "resuming"' not in renderer  # lifecycle uses explicit comparisons, not a switch branch
assert 'payload.state === "resuming"' in renderer
assert "suspendPlaybackClock" in host
assert "resumeAwaitingFreshSample" in bridge

# Player commands use ABI-checked selectors and never imply observed success.
assert 'NSSelectorFromString("setIsPaused:")' in bridge
assert "func performSkip(command:" in bridge
assert '"skipToNextTrackWithOptions:"' in bridge
assert '"skipToPreviousTrackWithOptions:"' in bridge
assert "verifyTransportEffect" in bridge
assert 'let names = ["seekTo:", "scrubTo:", "seekToPosition:"]' in bridge
assert "EeveeInvokeBoolArg" in bridge and "EeveeInvokeBoolArg" in c_header
assert "acknowledgeCommand" in renderer
assert "reconcileCommands" in renderer

# Desktop-style lyric behavior keeps timing types distinct and words intact.
assert 'dom.lyrics.dataset.timing' in renderer
assert "tokens: []" in renderer
assert 'element.classList.add("line-timed")' in renderer
assert ".lyric-line.line-timed.active > .line-text" in styles
assert ".lyric-line.not-sung" in styles
assert ".lyric-line.sung" in styles
assert ".word-group" in styles and "white-space: nowrap" in styles
assert "model.groupTokens(line.tokens)" in renderer
assert "joinsNext: syllable?.IsPartOfWord === true" in renderer
assert "model.lyricLineState" in renderer
assert "function lyricTimeScale(data)" in renderer
time_scale = renderer[
    renderer.index("function lyricTimeScale(data)"):
    renderer.index("const toMilliseconds")
]
assert "state.playback.durationMs" not in time_scale
assert "data?.TimeUnit" in time_scale
assert "return 1000;" in time_scale
assert "position -= state.preferences.playbackOffset" in renderer

# The resolver must retain the best timed payload and prevent Static from
# replacing Line/Syllable in memory or on disk.
assert "rendererCacheLifetime: TimeInterval = 3 * 24 * 60 * 60" in repository
assert "staticRendererCacheLifetime: TimeInterval = 30" in repository
assert "Joined in-flight request" in repository
assert "fetchBestRemotePayload" in repository
assert "isHigherQuality(existing, than: incoming)" in repository
assert r"Upgraded \(trackId) from \(best.type)" in repository
assert "SpicyLyricsServiceError.queued" in repository
assert "2 * pow(1.5, Double(queuedAttempt))" in repository
assert "forceRefresh: Bool = false" in repository
assert "shouldContinue: () -> Bool" in repository

# Native always publishes the current clock before starting the async lyric
# request for that generation.
publish = host[
    host.index("private func publishPlaybackAndTrack"):
    host.index("private func requestLyrics")
]
assert publish.index('emit(type: "playback"') < publish.index("requestLyrics(for:")

node = shutil.which("node")
assert node, "Node.js is required for renderer model regression tests"
subprocess.run(
    [node, "--check", str(BUNDLE / "renderer-model.js")],
    check=True,
)
subprocess.run(
    [node, "--check", str(BUNDLE / "renderer.js")],
    check=True,
)
subprocess.run(
    [node, str(ROOT / "Tests/SpicyLyricsRenderer/model.test.js")],
    check=True,
)

print("Spicy Lyrics renderer bundle policy tests passed")
