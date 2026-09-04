# Implementation Plan: Deterministic iOS Spicy Lyrics

Design: `docs/superpowers/specs/2026-09-04-spicy-lyrics-authoritative-playback-design.md`

## Core rewrite

- [x] Prove Spotify 9.1.76 state, unit, command, option, and restriction ABI from
  the target executable.
- [x] Replace multi-source/unit-guessing clock with an observation-only reducer.
- [x] Read live position from `SPTPlayerState`, removing Now Playing timeline
  fallback and the artificial perceptual lead.
- [x] Dispatch exact pause/resume/seek/skip/shuffle/repeat selectors with their
  verified Objective-C argument encodings.
- [x] Publish atomic protocol-v5 sessions with generation and sequence.
- [x] Bind lyric requests/results to request ID, track, and generation.
- [x] Separate requested commands from observed state and add one bounded seek
  preview with one native commit.
- [x] Freeze/resync lifecycle and recreate terminated WebKit content.

## Lyrics and interface

- [x] Move lyric normalization into a pure testable model.
- [x] Preserve syllable timing, join-next words, punctuation, contractions,
  duet/background vocals, transliteration, translations, and RTL.
- [x] Give line-timed lyrics real active/sung/future states.
- [x] Keep static lyrics readable without fake time.
- [x] Keep fullscreen mounted through next/previous and expose observed
  shuffle/repeat off/context/track.
- [x] Preserve safe areas, short landscape, enlarged lyric text, 44-point
  targets, visible focus, reduced motion, and increased contrast.
- [ ] After the full-screen core passes, expose the same session/lyrics model to
  compact Now Playing and video/Canvas without adding another clock.

## Data and recovery

- [x] Join concurrent lyric requests and choose highest fidelity.
- [x] Prevent a 404 or lower-fidelity refresh from replacing valid timed cache.
- [x] Keep privacy-safe diagnostic identity/state/type fields without tokens or
  lyric text.

## Verification and delivery

- [x] Add deterministic native state-machine tests.
- [x] Add deterministic renderer/session/seek/command/payload tests.
- [x] Add bundle policy, syntax, adaptive layout, accessibility, and cache
  invariants.
- [ ] Run browser interaction and visual regression at required viewports.
- [ ] Run macOS CI Swift tests and tweak build; fix every preserved failure.
- [ ] Download and inspect the fresh `.deb`.
- [ ] Repackage into the known-launching Spotify 9.1.76 IPA.
- [ ] Verify identity, resources, exactly one dylib load command, and SHA-256.
- [ ] Hand off one clearly named Sideloadly-ready IPA plus the focused device
  test list.
