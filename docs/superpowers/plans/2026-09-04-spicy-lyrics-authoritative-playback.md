# Implementation Plan: Authoritative Spicy Lyrics Playback

Design: `docs/superpowers/specs/2026-09-04-spicy-lyrics-authoritative-playback-design.md`

## 1. Replace the multi-writer playback clock

Files:

- `Sources/EeveeSpotify/Lyrics/SpicyLyricsPlaybackClock.swift`
- `Tests/SpicyLyricsPlaybackClock/main.swift`

Work:

1. Introduce a generation- and sequence-aware playback sample model.
2. Add explicit source authority and freshness rules.
3. Make context-player samples the normal position writer.
4. Reject stale, lower-authority, pre-seek, and prior-generation samples.
5. Model requested commands separately from observed player state.
6. Add deterministic tests for pause/resume, seek, track replacement,
   background/foreground, duplicate callbacks, and source arbitration.

Verification:

- Compile the clock and test harness with Swift on macOS CI.
- Run all deterministic clock scenarios with untouched assertions.

## 2. Add the context-player sampling coordinator

Files:

- `Sources/EeveeSpotify/Lyrics/SpicyLyricsPlaybackBridge.swift`
- `Sources/EeveeSpotify/Lyrics/Models/Headers/StatefulPlayerImplementation.swift`
- a new focused playback model/header file if required to keep the bridge small

Work:

1. Resolve `SPTStatefulPlayerTrackPositionAPI` dynamically from the captured
   stateful player.
2. Validate Objective-C method encodings before reading the synchronous
   `position`, `duration`, and `playbackSpeed` getters.
3. Timestamp each getter sequence with monotonic uptime and submit its midpoint
   sample to the clock.
4. Sample at an active visible cadence, immediately on state transitions, and
   slowly while paused.
5. Restrict observer callbacks to discrete playback state and sampling triggers.
6. Restrict Now Playing to startup/recovery fallback and prevent it from
   overwriting fresh context samples.
7. Include generation, sequence, source, shuffle, repeat, and freshness in the
   renderer payload.
8. Add privacy-safe diagnostic lines for sample and command reconciliation.

Verification:

- Static checks ensure there is one position writer in normal operation.
- Build validates all runtime bridging code against the target toolchain.

## 3. Reconcile every playback command

Files:

- `Sources/EeveeSpotify/Lyrics/SpicyLyricsPlaybackBridge.swift`
- `Tests/SpicyLyricsRenderer/test_bundle.py`

Work:

1. Remove optimistic clock mutations for play and pause.
2. Keep seek targets pending until a matching observed position sample arrives.
3. Keep skip pending until a different observed track identifier arrives.
4. Implement shuffle through the verified `setShuffle:` family.
5. Implement repeat through the verified repeat-mode API, cycling off, context,
   track, and off.
6. Return command request status separately from observed state.

Verification:

- Structural tests assert typed commands and non-optimistic behavior.
- Device verification confirms actual Spotify state after every command.

## 4. Make full-screen track changes atomic

Files:

- `Sources/EeveeSpotify/Lyrics/SpicyLyricsFullscreenHost.swift`
- `Tests/SpicyLyricsRenderer/test_bundle.py`

Work:

1. Give the host a canonical track generation.
2. On track change, clear old lyrics/timeline and publish the new loading state
   without dismissing the full-screen host.
3. Key metadata, playback, lyric fetches, and command results to the generation.
4. Discard every stale response after repeated next/previous actions.
5. Pause sampling when hidden and demand a fresh context sample before resuming
   animation after foregrounding.

Verification:

- Host contract tests cover stale lyric responses and repeated track changes.
- Renderer integration tests keep the page mounted while identity changes.

## 5. Use one renderer clock

Files:

- `layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer/renderer.js`
- `Tests/SpicyLyricsRenderer/test_bundle.py`

Work:

1. Replace the renderer's mutable command-time clock with interpolation from the
   latest authoritative native snapshot.
2. Stop play/pause/seek controls from changing observed playback locally.
3. Reset interpolation only on a newer sequence or generation.
4. Suspend interpolation on lifecycle loss and resume only after a fresh sample.
5. Validate and reset invalid legacy lyric offsets; apply a valid explicit
   offset once, after canonical position.
6. Ensure line and karaoke renderers consume the same computed position.

Verification:

- Deterministic JavaScript time fixtures cover delay, pause/resume, seek,
  correction, track change, and foreground behavior.

## 6. Port desktop lyric grouping and line presentation

Files:

- `layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer/renderer.js`
- `layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer/styles.css`
- renderer fixtures/tests

Work:

1. Group connected syllables using the desktop `IsPartOfWord` rule.
2. Render complete word containers that cannot wrap between their syllables.
3. Preserve punctuation, contractions, duet/background vocals, transliteration,
   and RTL direction.
4. Port desktop line-timed `NotSung`, `Active`, and `Sung` presentation,
   including active white state, scale, opacity, spacing, and focus scrolling.
5. Adapt desktop geometry to iPhone portrait and short landscape without
   changing timing semantics.
6. Keep static lyrics visually readable without fabricated timing.

Verification:

- DOM/geometry fixtures cover split words, punctuation, long lines, duet,
  background vocal, RTL, line timed, and static content.
- Render and inspect portrait and landscape screenshots.

## 7. Complete the full-screen transport

Files:

- `layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer/index.html`
- `layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer/styles.css`
- `layout/Library/Application Support/EeveeSpotify.bundle/SpicyLyricsRenderer/renderer.js`
- renderer tests

Work:

1. Render shuffle, previous, play/pause, next, and repeat in stable order.
2. Display observed shuffle and repeat modes, including repeat-one.
3. Use semantic buttons, accurate accessible names/states, visible focus, and
   at least 44-point touch regions.
4. Keep the seek bar, timestamps, and transport reachable at safe areas,
   enlarged text, and short heights.
5. Preserve reduced-motion behavior without removing state cues.

Verification:

- Automated structure/accessibility checks cover names, states, focusability,
  hidden branches, and activation geometry.
- Visual snapshots cover all transport states and orientations.

## 8. Run the local and CI verification matrix

Files:

- `.github/workflows/buildnopatch.yml`
- tests and QA artifacts as needed

Work:

1. Run renderer structural and browser tests locally.
2. Run Swift clock tests locally where the toolchain permits and in macOS CI.
3. Run syntax, diff, hidden-state, copy-integrity, and archive checks.
4. Trigger the existing macOS build workflow and preserve the first failure if
   one occurs.
5. Inspect the `.deb` for the updated dylib and renderer bundle.

Verification:

- All applicable automated checks pass without weakened assertions.
- Rendered QA is inspected independently of test success.

## 9. Produce and verify the Sideloadly IPA

Work:

1. Merge the freshly built tweak into the same known-launching Spotify 9.1.76
   base used by the current installation.
2. Confirm archive layout, main executable, load commands, dylib, resources,
   bundle identifier strategy, and SHA-256.
3. Give the user one clearly named IPA to install through Sideloadly.
4. Run the complete on-device scenario from the accepted design.
5. Keep the goal active until the user explicitly approves the device result.
