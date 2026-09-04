import pathlib


ROOT = pathlib.Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer"

index = (BUNDLE / "index.html").read_text(encoding="utf-8")
renderer = (BUNDLE / "renderer.js").read_text(encoding="utf-8")
styles = (BUNDLE / "styles.css").read_text(encoding="utf-8")
bridge = (ROOT / "Sources/EeveeSpotify/Lyrics/SpicyLyricsPlaybackBridge.swift").read_text(encoding="utf-8")
c_header = (ROOT / "Sources/EeveeSpotifyC/include/Tweak.h").read_text(encoding="utf-8")

assert 'src="renderer.js"' in index
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
assert "setLocalPlaying(!state.playback.isPlaying)" in renderer
assert "position -= state.preferences.playbackOffset" in renderer

print("Spicy Lyrics renderer bundle policy tests passed")
