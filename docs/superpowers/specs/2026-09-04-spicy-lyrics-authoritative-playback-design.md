# Deterministic iOS Spicy Lyrics Architecture

Date: 2026-09-04
Target: Spotify iOS 9.1.76, EeveeSpotify 6.3.12, iPhone 16 Pro

## Outcome

The full-screen Spicy Lyrics page must behave as one native Spotify playback
surface, not as a web page guessing at a second clock. Karaoke, line-timed, and
static payloads keep their real semantics. Pause, resume, seek, previous, next,
shuffle, repeat, lifecycle changes, and rapid track changes remain usable and
cannot mix state from different songs.

The full-screen core is the only implementation target in this phase. Compact
Now Playing and video/Canvas surfaces may later consume the same session and
lyrics models, but must not add another clock.

## Reproduced failures and required corrections

| Observed failure | Proven or bounded cause | Required behavior |
|---|---|---|
| Lyrics begin late or repair only after reopening | The old bridge read `position` from the wrong object and fell back to stale observer/Now Playing data | Read the computed `SPTPlayerState.position` synchronously and render its audible position immediately |
| Pause continues lyrics, then accumulates an offset | Multiple native/JavaScript anchors and command-time mutations | Only an observed player state may freeze or resume the clock |
| Seek stutters or snaps back | Every pre-seek sample was rejected natively while JavaScript also rewrote position | Keep all observations truthful; use one bounded local preview until an observed position confirms or times out |
| Skip loops old lyrics or leaves old page/metadata | Track and playback were separate messages with independently arriving fetches | Publish one atomic session and reject stale generations, sequences, and lyric responses |
| Shuffle/repeat do not work or highlight truthfully | Spotify 9.1.76 accepts object arguments, while the old bridge required primitive `BOOL` | Dispatch `NSNumber` through the verified selectors and style only observed state |
| Some desktop-karaoke songs become static/line on mobile | Racing requests could let the lowest-fidelity result win | Join in-flight requests, probe bounded upgrades, and never replace valid timed cache with lower fidelity or 404 |
| Non-karaoke timed lines never turn white | Line payload fields and static presentation were conflated | Use direct line `StartTime`/`EndTime` and explicit active/sung/future states |
| Lyrics break after backgrounding or WebKit termination | Hidden JavaScript kept a stale anchor and renderer termination removed the custom page | Freeze while hidden, require a fresh state on foreground, and recreate WebKit twice before native fallback |

## Verified Spotify 9.1.76 ABI

Static inspection of the target Spotify executable establishes this adapter:

- `SPTEsperantoPlayer.state -> SPTPlayerState`
- `SPTPlayerState.position`, `duration`, `playbackSpeed`, `isPlaying`,
  `isPaused`, `isLoading`, `isBuffering`, `track`, `options`, `restrictions`,
  `playbackId`, and `sessionID`
- `pause:`, `resume:`, `skipToPreviousTrackWithOptions:`,
  `skipToNextTrackWithOptions:`, `setShufflingContext:`,
  `setRepeatingContext:`, `setRepeatingTrack:`, and `seekTo:`

Disassembly shows `seekTo:` multiplies its `Double` argument by 1000, while
`SPTPlayerState` divides the corresponding protobuf values by 1000. The bridge
therefore reads and writes seconds. Shuffle/repeat/pause/resume/skip setters use
object arguments, not primitive booleans. Selector cascades and guessed units
are excluded from the normal path.

## One playback truth

`SpicyLyricsPlaybackClock` is a pure reducer. It accepts complete observations
of `SPTPlayerState` and emits immutable snapshots. Commands never mutate it.

Each snapshot contains:

- track, playback, and session identity;
- monotonically increasing generation and sequence;
- position, duration, playback rate, playing/paused/loading/buffering state;
- shuffle, repeat, and command restrictions;
- a foreground freshness gate.

A different track or playback identity starts a new generation. Older source
timestamps within the same playback and older receipt times are rejected.
Equal timestamps are valid because `SPTPlayerState.position` is a live computed
getter. Time is monotonic uptime, and interpolation stops whenever Spotify says
the player is paused, loading, buffering, or awaiting foreground resync.

The host polls the same state every 250 ms and receives immediate wakeups from
Spotify observer callbacks and post-command bursts. Polls and callbacks do not
form separate authorities; both re-read the same state object.

## Atomic native/WebKit protocol v5

The host sends one `session` envelope containing identity, clock, metadata,
artwork, restrictions, shuffle, and repeat. The renderer accepts a session only
when its generation is newer, or its sequence is newer inside the current
generation. It cannot render a new timeline with an old title or vice versa.

Lyrics requests carry track ID plus generation. A new request cancels the old
one, and completion is committed only when the host still owns the exact
request, track, and generation. WebKit applies the same check. Returning to a
previously seen track is safe because its generation is new.

Commands carry a request ID and generation. Native acknowledgement means only
“dispatched”; controls remain pending until a newer observed session proves the
effect. Timeouts restore observed state without inventing success.

Seek is the sole bounded speculative interaction. Dragging previews locally and
sends nothing. Releasing sends exactly one request and holds the requested
visual position for at most 2.2 seconds. A newer observation near the target
ends preview immediately; rejection, generation change, or timeout restores
the actual player position.

## Lyrics semantics

- Syllable payloads retain every real token start/end. `IsPartOfWord` joins the
  current token to the next one, matching desktop Spicy Lyrics. Complete words
  are non-wrapping groups. Closing punctuation, opening punctuation,
  contractions, transliteration, translations, duet alignment, background
  vocals, and RTL direction are preserved.
- Line payloads read `Text`, `StartTime`, and `EndTime` directly from each
  content entry. The active line turns white, future and sung lines remain
  distinct, and only the lead/interlude line controls scrolling.
- Static payloads remain readable and receive no fabricated timing or active
  highlight.
- All types use the same canonical rendered position. The optional user offset
  defaults to zero and is applied once after playback calculation.

## Lifecycle, cache, and recovery

Backgrounding freezes the last rendered instant. Foregrounding does not guess
hidden elapsed time; a synchronous fresh state read releases the gate. WebKit
termination recreates the renderer at most twice for the host lifetime, then
reveals Spotify's native surface.

One in-flight lyric request exists per track. A bounded retry may upgrade
Static to Line or Syllable. A manual refresh retains the last decodable payload
until a successful equal-or-higher-fidelity response replaces it. A transient
404 can never overwrite valid 200 data.

Diagnostics include generation, sequence, track ID, position, playback flags,
command name/dispatch result, payload type/count/timing range, and recovery
reason. They exclude access tokens and lyric text.

## UI-standard applicability record

| Rule family | Applicability and implementation | Evidence target |
|---|---|---|
| RT-05 layout/platform adaptation | Applies: iPhone portrait, landscape, short height, safe areas, enlarged lyrics, pointer/touch and focus all share one intrinsic layout | E1 source checks, E2 rendered viewports, E3 device |
| RT-07 navigation continuity | Applies narrowly: close/settings state and track-to-track continuity; skip never dismisses or replaces the full-screen route | E1 protocol tests, E2 interaction run, E3 device |
| RT-08 async/recovery | Applies: explicit loading/failure/retry, cancellation, stale-result rejection, bounded seek preview, lifecycle resync, cache downgrade prevention, WebKit recreation | E1 deterministic tests, E2 browser scenarios, E3 network/lifecycle device run |
| RT-10 accessibility | Applies: semantic buttons, observed `aria-pressed`, disabled restrictions, visible focus, 44-point targets, safe reflow, reduced motion, increased contrast | E1 structure checks, E2 viewport/accessibility inspection, E3 VoiceOver/touch |
| RT-16A media/playback | Fully applies: one player graph and timeline, stable media identity, truthful controls, three lyric alternatives, degraded recovery | E1 state-machine tests and ABI inspection, E2 simulated playback, E3 audible device verification |

E1 proves source/state invariants. E2 proves real HTML/CSS/JavaScript behavior in
a browser harness. E3 is required for Spotify-private ABI and audible sync; an
automated pass must not be described as device proof.

## Verification matrix

Automated:

1. Native reducer: first observation, equal/older timestamps, atomic generation
   swaps, partial identities, 100 pause/resume cycles, loading/buffering,
   lifecycle, restrictions, shuffle/repeat, and duration clamps.
2. Renderer model: huge ordinal ordering, first-open projection, pause freeze,
   seek preview/confirmation/rejection/timeout, command reconciliation, all
   lyric types, token grouping, punctuation, contraction, translation, duet,
   background, RTL, stale lyrics, and 250 adverse transition cycles.
3. Bundle policy: v5 contract, one state source, exact selectors, one seek
   commit, transport order/state, cache non-downgrade, lifecycle recovery,
   adaptive/accessibility rules, and JavaScript syntax.
4. Browser: portrait, landscape, short-height, enlarged text, reduced motion,
   karaoke fill, line highlight, static readability, pause, seek, skip,
   shuffle/repeat, stale sessions, and lifecycle transitions.
5. CI/archive: Swift tests, tweak build, resource inclusion, Spotify 9.1.76
   identity, exactly one Eevee dylib load command, and reproducible checksums.

Device acceptance:

1. Cold/cache-reset first open starts at the audible word/line.
2. Repeated pause/resume never drifts; background/foreground resynchronizes.
3. Seek is smooth and lands once without snap-back.
4. Next/previous keep full-screen mounted and swap all content atomically.
5. Shuffle and repeat off/context/track affect Spotify and match their icons.
6. Several known karaoke, line, and static songs work after revisit and rapid
   skipping in portrait and landscape.

The engineering goal can close after implementation, automated verification,
CI, archive inspection, and an install-ready handoff are complete. Device
testing remains the final empirical check, but user approval is not a goal-state
gate.
