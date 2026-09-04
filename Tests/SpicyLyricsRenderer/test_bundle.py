import pathlib


ROOT = pathlib.Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer"

index = (BUNDLE / "index.html").read_text(encoding="utf-8")
renderer = (BUNDLE / "renderer.js").read_text(encoding="utf-8")
styles = (BUNDLE / "styles.css").read_text(encoding="utf-8")
bridge = (ROOT / "Sources/EeveeSpotify/Lyrics/SpicyLyricsPlaybackBridge.swift").read_text(encoding="utf-8")
repository = (ROOT / "Sources/EeveeSpotify/Lyrics/Repositories/SpicyLyricsRepository.swift").read_text(encoding="utf-8")
c_header = (ROOT / "Sources/EeveeSpotifyC/include/Tweak.h").read_text(encoding="utf-8")

assert 'src="renderer.js?v=3"' in index
assert 'href="styles.css?v=3"' in index
assert "const RENDERER_PROTOCOL_VERSION = 3" in renderer
assert 'post("ready", { rendererProtocolVersion: RENDERER_PROTOCOL_VERSION })' in renderer
assert 'id="playback-offset"' in index
assert "preview-fixture" not in index
assert "SPICY_PREVIEW_LYRICS" not in renderer
assert not (BUNDLE / "preview-fixture.js").exists()
assert not (BUNDLE / "preview-cover.svg").exists()
assert 'dom.lyrics.dataset.timing' in renderer
assert 'tokens: []' in renderer
assert 'element.classList.add("line-timed")' in renderer
assert ".lyric-line.line-timed.active > .line-text" in styles
assert "function lyricTimeScale(data)" in renderer
assert "state.playback.durationMs" not in renderer[renderer.index("function lyricTimeScale(data)"):renderer.index("const toMilliseconds")]
assert 'data?.TimeUnit' in renderer
assert 'return 1000;' in renderer[renderer.index("function lyricTimeScale(data)"):renderer.index("const toMilliseconds")]
assert "source[index - 1]?.IsPartOfWord === true" in renderer
assert 'case "lifecycle"' in renderer
assert 'document.addEventListener("visibilitychange"' in renderer
assert 'NSSelectorFromString("setIsPaused:")' in bridge
assert "func performSkip(command:" in bridge
assert '"skipToNextTrackWithOptions:"' in bridge
assert '"skipToPreviousTrackWithOptions:"' in bridge
assert "verifyTransportEffect" in bridge
assert 'let names = ["seekTo:", "scrubTo:", "seekToPosition:"]' in bridge
assert "EeveeInvokeBoolArg" in bridge and "EeveeInvokeBoolArg" in c_header
assert "capturedPlayer ?? statefulCandidate" not in bridge
assert "requestedPlaybackState" in bridge
assert "positionAsOfTimestamp" in bridge
assert "SpicyLyricsPlaybackTimestampProjector.positionSeconds" in bridge
assert "Ignored out-of-order player state" in bridge
assert "setLocalPlaying(!state.playback.isPlaying)" in renderer
assert "position -= state.preferences.playbackOffset" in renderer
assert "rendererCacheLifetime: TimeInterval = 3 * 24 * 60 * 60" in repository
assert "staticRendererCacheLifetime: TimeInterval = 30" in repository
assert "Joined in-flight request" in repository
assert "fetchBestRemotePayload" in repository
assert "Upgraded \\(trackId) from \\(best.type)" in repository
assert "SpicyLyricsServiceError.queued" in repository
assert "2 * pow(1.5, Double(queuedAttempt))" in repository
assert "forceRefresh: Bool = false" in repository
assert "shouldContinue: () -> Bool" in repository

host = (ROOT / "Sources/EeveeSpotify/Lyrics/SpicyLyricsFullscreenHost.swift").read_text(encoding="utf-8")
publish = host[host.index("private func publishPlaybackAndTrack"):host.index("private func requestLyrics")]
assert publish.index('emit(type: "playback"') < publish.index("requestLyrics(for:")

print("Spicy Lyrics renderer bundle policy tests passed")
