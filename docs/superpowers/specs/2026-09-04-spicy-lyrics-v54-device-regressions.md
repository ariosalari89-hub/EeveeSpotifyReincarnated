# v5.4 device regressions and acceptance goal

This implements the user's current goal, including the later Sacrifice screenshots.
It is a scoped repair of the native/renderer integration, not another playback-clock rewrite.
The user has authorized implementation without another approval round.

## Failures to eliminate

1. Smart Shuffle: off → shuffle → Smart Shuffle → off when Spotify offers it; actual
   native state must confirm the icon. Unsupported contexts must remain two-state.
2. Above-title lyric: the same timed provider on still artwork, Canvas, and the migrated
   lyric element. No original layer underneath, including after native alpha animations,
   child replacement, visibility changes, song skips, or returning from full screen.
3. Preview: follow the current line automatically even after a finger/wheel gesture and
   scrolling the surrounding player. Coming back into view must align immediately.
4. Seek: acquire the thumb on touch-down, keep it stable while held, preview smoothly
   without a native seek on every move, commit once on release, cancel cleanly, and never
   allow a previous command's acknowledgement to settle a newer drag. Preserve native
   audio authority and the already working pause/resume/skip/repeat/clock behavior.
5. Opening: custom preview body and native header expand both enter Spicy directly,
   with one transition. Do not launch Spotify's native zoom and cover it afterwards.
6. Landscape: artwork remains on the left; remove the duplicate title/artist there.
   Keep bottom-left metadata, portrait metadata and all control hit targets.
7. Caption clipping: show the current phrase without ellipsis; fit short native
   slots by showing a measured, word-boundary segment containing the currently timed
   word. No arbitrary syllable spaces, hidden active word, truncated glyphs, or clipped
   interlude dots. Preserve true provider timestamps, RTL, line-timed and static fallback.

## Evidence and chosen design

- The supplied 9.1.76 binary's native toggle reads `contextURI`, while v5.3 only reads
  `contextURL`. The adapter then returns unavailable and falls into binary shuffle.
  The old fake used the same wrong property, concealing this. Fix the adapter and fake.
- v5.3 only maps CanvasNowPlayingLyricsView. Binary metadata also verifies
  Lyrics_NPVContainerKit.LyricsContainerView and
  NowPlaying_ContentLayersImpl.LegacyLyricsContainerView, both with lyricsTapped.
  Scope attachment to those classes, avoid nested renderers, and intercept their tap.
  CanvasNowPlayingLyricsElementView is the separately verified migrated-video variant
  and is included too. Scoped native tap recognizers are restored on detach; no global
  gesture recognizer or view behavior is changed.
- v5.3 hides native child alpha only during layout. A later native alpha animation can
  draw it again. Add a reversible transparent layer mask that preserves intrinsic size,
  and mask newly added children immediately. Do not mutate global UIView behavior.
- Preview drag/wheel disables follow forever, while its Follow button is deliberately
  hidden. Compact previews will always follow; expanded lyrics retain manual browsing.
- A seek starts only on `input`, so a finger holding an unmoved thumb does not own it:
  animation frames continue moving its value. Acquire on pointerdown; ignore old pending
  seek acknowledgements while a new pointer drag owns the position.
- Header expand is outside the current overlay. Read only the verified named UIView
  ivar of CardHeaderView, install a transparent accessible button over that exact native
  expand container, and preserve native share/translation controls and layout. Direct
  body/caption taps must not also activate the native ancestor tap.

## Execution and verification

- [x] Add native `contextURI`-only regression before the fix; verify real binary ABI.
- [x] Record preview/seek browser gesture failures, then retest actual pointer gestures.
- [x] Add native redraw/mask/child insertion and non-Canvas hook integration regressions.
- [x] Add header expand routing test with a native action counter (must stay zero).
- [x] Add caption segment/dot bounds and landscape duplicate-visibility tests.
- [ ] Run all model, bundle, browser, clock, C control, and UIKit/WK host tests.
- [ ] Inspect portrait/landscape/card/inline screenshots, errors and interactions.
- [ ] Full native build; package against preserved corrected base; archive/payload/hash
  checks; preserve v5.3. No uninstall, data reset, account/signing changes or phone install.
- [ ] Deliver one IPA with simple update-over-current Sideloadly instructions and honest
  distinction between automated coverage and actual physical Spotify verification.

No acceptance test may assume a capability/property just because the implementation
uses it. Simulated Spotify behavior must be explicitly labeled; local WebKit tests cannot
prove every private runtime layout or account capability on the user's phone.

Primary references consulted: Apple's object_getIvar and WKWebView.scrollView
documentation, plus supplied Spotify binary metadata/disassembly. Runtime API docs
establish mechanics, not private Spotify semantics; those require the binary/phone.

- [Apple object_getIvar](https://developer.apple.com/documentation/objectivec/object_getivar(_:_:))
- [Apple WKWebView.scrollView](https://developer.apple.com/documentation/webkit/wkwebview/scrollview)

The compact preview intentionally always follows, matching its preview role; manual
reading is available by expanding it. Untimed text also expands on tap/Enter, with no
fake current line or seek. Full-screen manual scrolling/Follow control is unchanged.

### Reproduction evidence (v5.3 before repair)

Preview: 360×320, 30 line-timed lines, pause at 1s; wheel down 360px over
the actual card, then observe playback at 45s. Active line 22 is at y=503.8px,
outside the 320px viewport, while the Follow control has zero height. Screenshots:
`artifacts/spicy-v5.4-qa/preview-before-r2.png` and `preview-stuck-r2.png`.
This is an actual browser wheel gesture, not a dispatched DOM wheel event.
Video recording was unavailable because the browser CLI could not find ffmpeg;
discard the earlier blank fixture capture, retain the numbered r2 screenshots.

The same actual thumb-hold test against archived shipping v5.3 (`89a4b6a`) jumps
from 10000 to 20200ms while the pointer is held still. v5.4 stays at 10000ms,
then follows a real move to 8800ms and emits exactly one native seek on release.
The first v5.4 pointerup implementation exposed a new browser event-order failure
(zero seeks on release); replacing the premature microtask with a post-change task
fixes that regression. Both failures were observed, not inferred from source alone.

Native red run `33930117133` at `b0eff6c`: FAIL "shuffle dispatch failed" with the
real contextURI-only state. The source fix reads contextURI before contextURL.
All existing model/bundle/control/lifecycle/browser scenarios pass locally after
the repair. Added actual-gesture tests cover hold/drag/release, card wheel/reentry,
timed caption pages, line-timed glyph bounds, dots and landscape metadata.
