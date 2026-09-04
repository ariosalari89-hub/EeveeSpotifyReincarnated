import pathlib


ROOT = pathlib.Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer"

index = (BUNDLE / "index.html").read_text(encoding="utf-8")
renderer = (BUNDLE / "renderer.js").read_text(encoding="utf-8")

assert 'src="renderer.js"' in index
assert "preview-fixture" not in index
assert "SPICY_PREVIEW_LYRICS" not in renderer
assert not (BUNDLE / "preview-fixture.js").exists()
assert not (BUNDLE / "preview-cover.svg").exists()
assert 'dom.lyrics.dataset.timing' in renderer
assert 'tokens: []' in renderer

print("Spicy Lyrics renderer bundle policy tests passed")
