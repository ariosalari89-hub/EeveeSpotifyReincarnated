# Desktop Spicy Lyrics Full-Screen Renderer for iOS

Date: 2026-09-03

## Goal

Replace Spotify 9.1.76's full-screen lyrics surface with a local renderer that
matches the desktop Spicy Lyrics experience: word/syllable-progressive karaoke,
smooth line choreography, a moving album-art background, track metadata, seek
progress, transport controls, translations/romanization when present, and the
same high-contrast visual hierarchy. Keep Spotify's compact Now Playing lyrics
card unchanged.

## Compatibility boundary

- Primary target: Spotify 9.1.76 on iPhone 16 / current iOS.
- Hook only `Lyrics_FullscreenElementPageImpl.FullscreenElementViewController`.
- Check the class and lifecycle methods at runtime. If the class, resources,
  JavaScript runtime, lyrics payload, or playback bridge are unavailable, leave
  Spotify's native full-screen lyrics untouched.
- Do not expose Spotify bearer tokens or execute remote JavaScript in the web
  view. Swift performs authenticated requests and passes only display data.

## Architecture

### Native host

`SpicyLyricsFullscreenHost` owns one `WKWebView` per presented full-screen lyrics
controller. It loads bundled HTML/CSS/JavaScript from
`EeveeSpotify.bundle/SpicyLyricsRenderer`, covers the entire controller view,
and observes the same player service Spotify already exposes.

The host emits structured events to JavaScript:

- `bootstrap`: capabilities and accessibility preferences.
- `track`: track id, title, artist, album, artwork, duration.
- `lyrics`: loading, ready, unavailable, or failed plus parsed Spicy payload.
- `playback`: observed position, duration, playing state, playback rate, and a
  monotonically increasing sequence number.
- `commandResult`: whether a requested native player command was accepted.

JavaScript sends typed commands through one message handler:

- `ready`, `close`, `seek`, `togglePlay`, `previous`, `next`.
- `setPreference` for renderer-only options.
- Every user command has a request id. A tap shows a pending state, but the UI
  treats observed playback state—not the tap itself—as authoritative.

### Lyrics data

`SpicyLyricsRepository` continues producing Spotify-compatible line lyrics for
the native fallback. In parallel it caches a renderer payload converted from the
decoded SLObjPack tree. This retains all timing and role information that the
old DTO discarded: lead syllables, start/end times, word-continuation flags,
background vocals, interludes, translations, transliterations, and content
type. The token remains native-only.

The full-screen host requests/caches this payload by Spotify track id. A stale
response is discarded if the song changes before it arrives.

### Web renderer

The bundle is framework-free, deterministic, and local:

- Semantic HTML buttons and range input with VoiceOver labels and at least
  44-point touch targets.
- CSS recreates the desktop two-column full-screen layout on landscape/tablet
  and a compact stacked layout on portrait phones, respecting safe-area insets.
- A canvas samples the album art and renders slow blurred color fields. It
  cross-fades on song changes, slows when paused, and falls back to a static
  blurred image/gradient if canvas or image loading fails.
- JavaScript normalizes `Syllable`, `Line`, and `Static` Spicy payloads into
  render lines. Syllable timing drives a continuous left-to-right fill per
  syllable/word rather than snapping whole labels. Lead, duet, and background
  vocal roles receive separate layout and opacity treatment.
- `requestAnimationFrame` interpolates between native playback snapshots. The
  bridge sends updates at a modest rate; it never sends 60 messages per second.
- Active-line scrolling is spring-smoothed and manual lyric taps seek to the
  line start. Interludes render as animated beat dots.
- Reduced Motion disables canvas movement, parallax, scaling, and spring
  overshoot while preserving readable karaoke progress.

## Visual structure

The hierarchy follows desktop Spicy Lyrics:

1. Edge-to-edge, artwork-derived animated background with dark contrast veil.
2. Top chrome: close button, centered `Spicy Lyrics`, overflow/settings button.
3. Media/lyrics stage:
   - wide screens: square artwork and track info on the left, lyrics on the right;
   - portrait: compact track header above a dominant scrollable lyric column.
4. Bottom player: track/artist, seek bar and timestamps, previous/play/next.

No construction labels, placeholder debug text, or token/account data appear in
the shipped UI.

## States and fallback

- Loading: skeleton lines and a quiet `Loading lyrics…` status.
- No timed lyrics: line/static lyrics remain readable; progress animation is
  omitted rather than fabricated.
- Offline/API failure: show a concise retry state. If there is no usable cached
  payload, automatically remove the overlay and reveal Spotify's native view.
- Web content-process termination or navigation failure: detach renderer and
  reveal native UI immediately.
- Track change: keep the shell and controls, cross-fade metadata/background, and
  replace lyrics only when the matching new response arrives.

## Verification

- Unit-test payload conversion/normalization using syllable, line, static,
  background-vocal, interlude, RTL, missing-field, and malformed fixtures.
- Browser-test the local bundle at representative iPhone portrait and landscape
  sizes, including long lyrics, small screens, increased text, and reduced
  motion. Inspect screenshots rather than relying only on DOM assertions.
- Build the tweak in the macOS GitHub Actions environment and verify the bundle
  is present in the `.deb` and final IPA.
- Confirm the IPA starts from the exact previously working 9.1.76 base rather
  than nesting a second injection.
- On device: confirm launch, open/close full-screen repeatedly, play/pause,
  seek, next/previous, song change, background transition, word fill timing,
  rotation/safe areas, VoiceOver labels, and native fallback.

## Licensing

The renderer is an original mobile adaptation informed by desktop Spicy Lyrics.
Any source fragments copied from the AGPL-3.0 desktop project must retain their
license notice and make the corresponding source available with the build.
