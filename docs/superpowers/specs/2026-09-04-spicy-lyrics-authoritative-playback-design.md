# Authoritative Spicy Lyrics Playback and Desktop-Parity Rendering

Date: 2026-09-04

## Context

The current iOS renderer has multiple writers for playback time. Spotify player
observer callbacks, `MPNowPlayingInfoCenter`, synchronous KVC reads, the native
prediction clock, and a second JavaScript prediction clock can each replace the
same timeline anchor. A delayed callback can therefore overwrite a newer value.
This explains the repeatable symptoms: lyrics start late, pause/resume creates a
lasting offset, returning from the background changes synchronization, and song
changes sometimes retain the previous song's clock.

The Spotify 9.1.76 binary contains the interfaces needed to remove this
ambiguity: `SPTStatefulPlayerTrackPositionAPI`,
`getPositionState:onResponse:`, `setShuffle:`, and
`setRepeatMode:completionHandler:`. The desktop Spicy Lyrics source also provides
the reference behavior for sampling progress, grouping syllables into words,
and presenting line-timed lyrics.

## Outcome

The full-screen iOS Spicy Lyrics surface must remain synchronized without users
repairing it by pausing, seeking, closing, reopening, or clearing a cache.
Karaoke lyrics must animate at word/syllable resolution. Line-timed lyrics must
use the desktop Spicy Lyrics presentation and active-line choreography. Playback
controls must remain attached to the current Spotify track while the full-screen
surface stays open.

## Scope

This design changes:

- the native playback state and command bridge;
- the full-screen host's track and lyric lifecycle;
- the bundled HTML/CSS/JavaScript renderer;
- deterministic native and renderer tests;
- the build artifact used for device verification.

It includes play/pause, previous, next, seek, shuffle, and repeat controls. It
also includes cold launch, cache reset, background/foreground, pause/resume,
seek, and repeated song-change recovery.

The compact Now Playing lyrics card and video/Canvas integration remain a later
phase. They must not be started until this full-screen timing and transport
contract passes on the target iPhone.

## Canonical playback model

### Snapshot

One native coordinator owns playback truth and publishes immutable snapshots:

```text
PlaybackSnapshot
  sequence
  generation
  trackID
  sampledPositionMilliseconds
  emittedPositionMilliseconds
  sampledAtUptime
  durationMilliseconds
  playbackRate
  isPlaying
  shuffleEnabled
  repeatMode: off | context | track
  source: contextPlayer | observer | nowPlayingFallback
  freshness
```

`generation` changes whenever the canonical track identifier changes.
`sequence` increases for every accepted snapshot within that generation.
Renderer events carrying an older generation or sequence are ignored.

### Source authority

The local Spotify context player's asynchronous position API is the sole normal
writer of the position anchor. The coordinator timestamps the request and
response using monotonic uptime, assigns the sample to the request/response
midpoint, and projects the returned position to emission time while playing.
This mirrors the desktop Spicy Lyrics progress strategy without exposing a
native clock that JavaScript cannot compare directly.

Player observer callbacks remain authoritative for discrete events: track
identity, play/pause state, playback rate, duration, shuffle, repeat, and
restrictions. They trigger an immediate position sample but do not independently
replace a fresh position anchor.

`MPNowPlayingInfoCenter` is fallback-only. It may seed a clock when the context
player API has produced no usable sample within a bounded startup interval. It
must never overwrite a fresher context-player sample or run as a competing
periodic writer. The payload records the source so fallback behavior can be
diagnosed without presenting it as context-player truth.

### Sampling and interpolation

While full-screen lyrics are visible and playback is active, the native bridge
samples the context player frequently enough to correct drift while JavaScript
uses `requestAnimationFrame` for smooth visuals. Paused playback receives an
immediate confirmation sample and low-frequency health samples. Track changes,
seek requests, play/pause transitions, app foregrounding, and renderer readiness
all trigger immediate samples.

JavaScript stores only the last native snapshot and its local receipt time. It
may interpolate forward from `emittedPositionMilliseconds` while that snapshot
says playback is active. It never makes an independent pause/resume/seek anchor,
never applies a second smoothing filter, and never treats a command acknowledgement
as observed playback.

The optional user lyric offset remains a separate explicit renderer preference,
defaults to zero, and is applied only after canonical position calculation. A
legacy or invalid stored value is reset rather than silently creating systemic
delay.

## Playback commands

Every command has a request identifier and the generation of the track against
which it was issued. The renderer presents a bounded pending interaction but
does not change canonical state until a later snapshot confirms the effect.

- Play and pause call Spotify's playback controls, then request an immediate
  position sample. A pause freezes at the observed post-command position. Resume
  continues from that same position; pausing is never a synchronization repair.
- Seek sends the requested position and waits for a context-player sample near
  the target. Pre-seek samples cannot restore the old anchor.
- Previous and next remain pending until the observed track identifier changes
  or Spotify confirms no change. The host stays mounted throughout.
- Shuffle toggles from the observed value and settles only when Spotify reports
  the new state.
- Repeat cycles `off -> context -> track -> off` and settles only when Spotify
  reports the new mode.

Timeout or unavailable selectors result in the control returning to its actual
observed state. The interface does not imply that a command succeeded merely
because the invocation was accepted.

## Atomic track transitions

When a new canonical track identifier is observed, the host performs one atomic
generation transition:

1. increment the generation and invalidate all earlier position, metadata,
   command, and lyric responses;
2. publish the new identity and a loading lyric state while clearing the old
   lyric document and old timeline;
3. obtain the first authoritative position sample for the new generation;
4. request the best available lyric payload keyed by the new track and
   generation;
5. publish metadata, playback, and matching lyrics without dismissing or
   recreating the full-screen surface.

If the user skips repeatedly, only the latest generation can become visible.
Returning to an earlier song starts a fresh generation even when its lyrics are
served from cache.

## Desktop-parity lyric rendering

### Karaoke and syllable lyrics

The renderer retains each syllable's start/end time and continuous fill. It
copies the desktop grouping rule rather than rendering every syllable as an
independent wrapping box: adjacent tokens connected by `IsPartOfWord` are placed
inside one non-wrapping word group. Line wrapping occurs only between complete
word groups. Spacing is emitted between words, not inside a connected word;
punctuation, contractions, background vocals, duet alignment, transliteration,
and RTL direction remain intact.

The active syllable fill is computed directly from canonical position. A new
snapshot can correct interpolation without restarting an animation or changing
which lyric document owns the line.

### Line-timed lyrics

Line-timed content is not rendered as simplified mobile text. It receives the
desktop Spicy Lyrics state model and presentation:

- `NotSung`, `Active`, and `Sung` states derived from line start/end times;
- a white active line, subdued future and past lines, and the desktop active
  scale hierarchy;
- smooth focus scrolling that follows the active line without trapping the
  document at the point where lyrics were opened;
- desktop-compatible line spacing, weight, duet/opposite alignment, RTL, and
  background-vocal treatment adapted to the available iPhone width;
- line taps that seek to the line start and then reconcile to observed playback.

Static lyrics remain readable but do not fabricate timing or active highlighting
when the payload contains no timeline.

### Layout and controls

The existing Spicy Lyrics visual language remains: artwork-derived background,
track identity, dominant lyric column, and bottom transport. Portrait and short
landscape layouts adapt to safe areas without shrinking the desktop behaviors
into an unusable canvas.

The full-screen transport order is:

```text
shuffle  previous  play/pause  next  repeat
```

Each control has at least a 44-point activation region and an accessible name.
Shuffle and repeat use both icon/state treatment and accurate accessibility
state; repeat distinguishes context and track modes. The seek control and time
labels remain reachable and do not overlap the lyric viewport at enlarged text
or short heights.

## Lifecycle and recovery

- Renderer readiness requests the latest snapshot and current generation; it
  does not reuse a clock serialized by a prior web view.
- Backgrounding suspends animation and sampling without advancing a hidden
  JavaScript clock. Foregrounding obtains a fresh context-player sample before
  animation resumes.
- Web-content termination reveals Spotify's native surface rather than leaving
  an inert overlay.
- Missing context-player APIs use the bounded fallback source and record that
  limitation. Unsupported command controls are unavailable rather than fake.
- Lyric fetch failures retain working transport and provide the existing concise
  retry/fallback path. A failed lyric request cannot replace a newer generation.

## Diagnostics

Debug logging records generation, sequence, source, sample round-trip time,
position, discrete playback state, accepted/rejected callback reason, command
request, command settlement, and lyric-payload type. It excludes account tokens
and lyric text. Log entries make it possible to distinguish provider timing,
native bridge timing, and renderer receipt timing on the target device.

## Verification

### Native deterministic tests

- context-player samples use the round-trip midpoint and project correctly;
- lower-authority or older samples cannot overwrite a fresh context sample;
- pause freezes indefinitely and resume continues from the frozen point;
- repeated pause/resume never accumulates offset;
- stale pre-seek and prior-generation samples are rejected;
- track changes at zero, nonzero, and repeated IDs reset correctly;
- background/foreground requires a fresh sample before advancing;
- shuffle and repeat commands remain pending until observed state confirms them.

### Renderer tests

- line-timed lyrics transition `NotSung -> Active -> Sung`, turn the active line
  white, scale and scroll like desktop, and remain synchronized after pause,
  resume, seek, and new snapshots;
- karaoke fill uses canonical position and does not restart on corrections;
- `IsPartOfWord` fixtures for split words, contractions, punctuation, duet,
  background vocal, and RTL render complete non-wrapping words;
- static lyrics never receive fabricated timed highlighting;
- next/previous track generations clear stale lyrics and load the new track;
- shuffle, previous, play/pause, next, repeat, and seek publish the correct typed
  commands and reflect only observed state;
- hidden branches are absent from layout, focus, hit testing, and accessibility;
- portrait, landscape, short-height, long-line, enlarged-text, reduced-motion,
  and safe-area fixtures contain all controls and lyric content.

### Build and device evidence

The tweak and renderer are built in the existing macOS workflow. The resulting
`.deb` and Sideloadly-ready IPA are inspected for the intended dylib, bundle,
renderer assets, and load commands. Static and browser-renderer tests are E1/E2
evidence only.

Final acceptance requires an on-device run on the target iPhone with the same
Spotify 9.1.76 base. The test sequence is:

1. clear the Spicy Lyrics cache, cold-launch Spotify, and open a known karaoke
   song;
2. verify immediate synchronization, pause for several seconds, resume, seek,
   background/foreground, and revisit the song after skipping away;
3. repeat with several karaoke songs previously reported as intermittent;
4. repeat with line-timed non-karaoke songs and verify desktop presentation;
5. use next and previous repeatedly while full-screen lyrics remains open and
   verify the displayed metadata, timeline, and lyrics always become the new
   track;
6. toggle shuffle and cycle all repeat modes, confirming the actual Spotify
   behavior and displayed state;
7. inspect portrait and landscape for chopped words, clipping, overlap, and
   inaccessible controls.

The goal remains incomplete until the user explicitly approves this on-device
result. A successful build, deterministic test suite, or isolated successful
song does not substitute for that approval.

## Acceptance criteria

- Karaoke and line-timed lyrics begin at the audible position with no systemic
  delay and do not drift during ordinary playback.
- Pause/resume preserves exact lyric position every time and never breaks or
  repairs synchronization.
- Seek, previous, next, play/pause, shuffle, and all repeat modes work and reflect
  observed Spotify state.
- Skipping while the full-screen lyric surface is open keeps it open and loads
  the new song's metadata, timeline, and lyric page.
- Karaoke words are not fragmented across lines or visibly cut into incorrect
  pieces.
- Line-timed non-karaoke lyrics match the desktop Spicy Lyrics presentation and
  active-line behavior.
- Cache reset, cold launch, repeated skip, returning to a song,
  background/foreground, and multiple pause/resume cycles do not reintroduce
  delay or desynchronization.
- The final IPA installs and launches on the target device, and the user gives
  explicit approval after testing.
