import pathlib
import shutil
import subprocess


ROOT = pathlib.Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer"

index = (BUNDLE / "index.html").read_text(encoding="utf-8")
model = (BUNDLE / "renderer-model.js").read_text(encoding="utf-8")
renderer = (BUNDLE / "renderer.js").read_text(encoding="utf-8")
styles = (BUNDLE / "styles.css").read_text(encoding="utf-8")
browser_fixture = (ROOT / "Tests/SpicyLyricsRenderer/browser-fixture.js").read_text(
    encoding="utf-8"
)
bridge = (ROOT / "Sources/EeveeSpotify/Lyrics/SpicyLyricsPlaybackBridge.swift").read_text(encoding="utf-8")
clock = (ROOT / "Sources/EeveeSpotify/Lyrics/SpicyLyricsPlaybackClock.swift").read_text(encoding="utf-8")
host = (ROOT / "Sources/EeveeSpotify/Lyrics/SpicyLyricsFullscreenHost.swift").read_text(encoding="utf-8")
repository = (
    ROOT / "Sources/EeveeSpotify/Lyrics/Repositories/SpicyLyricsRepository.swift"
).read_text(encoding="utf-8")
c_header = (ROOT / "Sources/EeveeSpotifyC/include/Tweak.h").read_text(encoding="utf-8")

# One explicit v5 contract and cache key must cover every shipping asset.
assert 'src="renderer-model.js?v=5"' in index
assert 'src="renderer.js?v=5"' in index
assert 'href="styles.css?v=5"' in index
assert "const RENDERER_PROTOCOL_VERSION = 5" in renderer
assert "private static let rendererProtocolVersion = 5" in host
assert 'post("ready", { rendererProtocolVersion: RENDERER_PROTOCOL_VERSION })' in renderer

# Preview-only content and debug credentials may not ship.
assert "preview-fixture" not in index
assert "SPICY_PREVIEW_LYRICS" not in renderer
assert "spotifyAccessToken" not in renderer
assert not (BUNDLE / "preview-fixture.js").exists()
assert not (BUNDLE / "preview-cover.svg").exists()

# The renderer receives a single atomic session; the split v4 track/playback
# protocol is gone. Stale generations and sequences are rejected in pure code.
assert 'emit(type: "session", payload: payload)' in host
assert 'case "session"' in renderer
assert 'case "track"' not in renderer
assert 'case "playback"' not in renderer
assert "shouldAcceptSession" in model and "shouldAcceptSession" in renderer
assert "compareOrdinal" in model
assert "activeGeneration == generation" in host
assert "lyricsRequestID == requestID" in host
assert "shouldAcceptLyrics" in model and "shouldAcceptLyrics" in renderer

# There is exactly one native playback truth: SPTPlayerState. Commands never
# optimistically mutate the clock or use MPNowPlayingInfo as position fallback.
assert 'NSSelectorFromString("state")' in bridge
assert "stateObject(from: player)" in bridge
assert 'safeDouble(state, key: "position")' in bridge
assert 'safeDouble(state, key: "duration")' in bridge
assert "MPNowPlayingInfoPropertyElapsedPlaybackTime" not in bridge
assert "perceptualLead" not in bridge
assert "pendingSeekTarget" not in clock
assert "requestedPlaybackState" not in bridge
assert "Commands never change this state" in clock
assert "projectedPosition" in model
assert "requiresFreshObservation" in clock and "requiresFreshObservation" in model

# Spotify 9.1.76's verified ABI is encoded exactly. Seek is a Double in
# seconds; transport uses nil object options; shuffle/repeat use NSNumber.
for selector in (
    '"pause:"',
    '"resume:"',
    '"seekTo:"',
    '"skipToNextTrackWithOptions:"',
    '"skipToPreviousTrackWithOptions:"',
    '"setShufflingContext:"',
    '"setRepeatingContext:"',
    '"setRepeatingTrack:"',
):
    assert selector in bridge
assert "invokeDouble" in bridge and "EeveeSBInvokeSeekDouble" in bridge
assert "NSNumber(value: !current)" in bridge
assert "EeveeInvokeObjectArg" in bridge and "EeveeInvokeObjectArg" in c_header
assert "selector cascade" in bridge
assert "scheduleObservationBurst" in bridge

# Requested commands remain pending until an observed session proves their
# effect. Seek sends only on change and maintains one bounded local preview.
assert "commandObserved" in model and "commandObserved" in renderer
assert "acknowledgeCommand" in renderer and "reconcileCommands" in renderer
assert 'dom.seek.addEventListener("input"' in renderer
assert 'dom.seek.addEventListener("change"' in renderer
seek_input = renderer[renderer.index('dom.seek.addEventListener("input"'):
                      renderer.index('dom.seek.addEventListener("change"')]
assert 'post("seek"' not in seek_input
assert "beginSeekPreview" in model and "reconcileSeekPreview" in model
assert "deadlineAt" in model
assert "state.seekPreview?.requestId === requestId" in renderer
assert "state.seekPreview.requestId = requestId" in renderer

# Full transport stays in the lyrics page and reflects only observed state.
transport_ids = [
    'id="shuffle-button"',
    'id="previous-button"',
    'id="play-button"',
    'id="next-button"',
    'id="repeat-button"',
]
positions = [index.index(item) for item in transport_ids]
assert positions == sorted(positions)
assert "session.shuffleEnabled" in renderer
assert "session.repeatMode" in renderer
assert "session.canGoPrevious" in renderer and "session.canGoNext" in renderer
assert 'case "togglePlay", "play", "pause", "next", "previous", "toggleShuffle", "cycleRepeat"' in host
assert 'case "next"' in bridge and 'case "previous"' in bridge
assert "guard canContext else { return true }" in bridge

# Karaoke, line, and static payloads stay semantically distinct. Word joins,
# punctuation, RTL, translations, backgrounds, and duet alignment are retained.
assert "normalizeSyllable" in model
assert "normalizeLine" in model
assert "normalizeStatic" in model
assert "previousRaw?.IsPartOfWord === true" in model
assert "startsWithClosingPunctuation" in model
assert "translationFrom" in model
assert 'kind: "background"' in model
assert "OppositeAligned" in model
assert "isRTL" in model
assert "groupTokens" in model and "groupTokens" in renderer
assert "tokenProgress" in model and "tokenProgress" in renderer
assert 'element.classList.add("line-timed")' in renderer
assert ".lyric-line.line-timed.active > .line-text" in styles
assert ".lyric-line.static" in styles
assert "white-space: nowrap" in styles

# Lifecycle and WebKit failures cannot run a hidden clock forever.
assert "suspendPlaybackClock" in host
assert "resumeAwaitingObservation" in host
assert "recoverOrFallBack" in host
assert "maximumWebContentRestarts" in host
assert "webViewWebContentProcessDidTerminate" in host
assert 'payload.state === "hidden" || payload.state === "resuming"' in renderer
assert "isRecoveringRenderer" in host
assert "rendererStabilityInterval" in host
assert "guard webView === self.webView" in host

# Lower-fidelity API races can improve in place without blanking already valid
# lyrics. This is bounded and never lets a Static/404 response overwrite a
# working Line/Syllable cache entry.
assert "lyricsUpgradeDelays" in host
assert "scheduleLyricsUpgrade" in host
assert "showLoading: false" in host

# Accessibility/adaptive layout invariants.
assert 'aria-label="Turn shuffle on"' in index
assert 'aria-label="Turn repeat on"' in index
assert 'class="repeat-one"' in index
assert "height: 44px" in styles
assert "button:focus-visible" in styles
assert "prefers-reduced-motion" in styles and "native-reduce-motion" in styles
assert "prefers-contrast: more" in styles
assert "safe-area-inset" in styles
assert "max-height: 520px" in styles
assert 'role="dialog"' in index and 'aria-modal="true"' in index
assert "dom.app.inert = open" in renderer
assert "min-height: 44px" in styles

# Artwork and pending command state stay generation-safe during rapid skips.
assert "artworkRequest" in renderer
assert "request !== this.artworkRequest" in renderer
assert "[...state.pendingCommands.keys()].forEach(settleCommand)" in renderer

# Cache refresh and racing responses can upgrade fidelity, never downgrade it.
assert "Joined in-flight request" in repository
assert "fetchBestRemotePayload" in repository
assert "isHigherQuality(existing, than: incoming)" in repository
assert "incoming.status == 404" in repository
assert "preservedPayload" in repository
assert "Refresh failed; retained" in repository
assert "SpicyLyricsServiceError.queued" in repository
assert "2 * pow(1.5, Double(queuedAttempt))" in repository
assert "rawBody" not in repository

node = shutil.which("node")
assert node, "Node.js is required for renderer regression tests"
subprocess.run([node, "--check", str(BUNDLE / "renderer-model.js")], check=True)
subprocess.run([node, "--check", str(BUNDLE / "renderer.js")], check=True)
subprocess.run(
    [node, "--check", str(ROOT / "Tests/SpicyLyricsRenderer/browser-fixture.js")],
    check=True,
)
subprocess.run(
    [node, str(ROOT / "Tests/SpicyLyricsRenderer/model.test.js")],
    check=True,
)

print("Spicy Lyrics renderer bundle policy tests passed")
