import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func requireNear(
    _ value: Double,
    _ expected: Double,
    tolerance: Double = 0.001,
    _ message: String
) {
    require(abs(value - expected) <= tolerance, "\(message): expected \(expected), got \(value)")
}

var secondsUnits = SpicyLyricsPlaybackUnitNormalizer()
let secondsDuration = secondsUnits.durationSeconds(193_000)
requireNear(secondsDuration, 193, "millisecond duration was not normalized")
requireNear(
    secondsUnits.positionSeconds(2, durationSeconds: secondsDuration, referenceSeconds: 2),
    2,
    "seconds position was divided because duration used milliseconds"
)

var millisecondsUnits = SpicyLyricsPlaybackUnitNormalizer()
let millisecondsDuration = millisecondsUnits.durationSeconds(193_000)
requireNear(
    millisecondsUnits.positionSeconds(100, durationSeconds: millisecondsDuration, referenceSeconds: 0.1),
    0.1,
    "early millisecond position did not use the system clock reference"
)
requireNear(
    millisecondsUnits.positionSeconds(2_000, durationSeconds: millisecondsDuration, referenceSeconds: 2),
    2,
    "learned millisecond position scale was not retained"
)

requireNear(
    SpicyLyricsPlaybackTimestampProjector.positionSeconds(
        anchorPositionSeconds: 12,
        fallbackPositionSeconds: 12,
        sourceTimestamp: 100,
        callbackTimestamp: 102.5,
        playbackRate: 1,
        isPlaying: true
    ),
    14.5,
    "late fallback callback was not projected forward"
)

private func sample(
    _ clock: inout SpicyLyricsPlaybackClock,
    position: Double,
    sampledAt: Double,
    receivedAt: Double? = nil,
    playing: Bool = true,
    track: String = "track-a",
    duration: Double = 180,
    source: SpicyLyricsPlaybackSampleSource = .statefulPlayer,
    generation: UInt64? = nil
) -> Bool {
    let currentGeneration: UInt64
    if clock.generation == 0 {
        currentGeneration = clock.transition(to: track, at: sampledAt)
    } else {
        currentGeneration = generation ?? clock.generation
    }
    return clock.submit(
        SpicyLyricsPlaybackSample(
            generation: generation ?? currentGeneration,
            positionSeconds: position,
            durationSeconds: duration,
            playbackRate: 1,
            isPlaying: playing,
            trackIdentifier: track,
            source: source,
            sampledAtUptimeSeconds: sampledAt,
            receivedAtUptimeSeconds: receivedAt ?? sampledAt
        )
    )
}

// A stateful-player sample is the single normal writer and projects smoothly
// from the represented sample instant.
var liveClock = SpicyLyricsPlaybackClock()
require(sample(&liveClock, position: 10, sampledAt: 1, receivedAt: 1.04), "live sample rejected")
requireNear(liveClock.snapshot(at: 2).positionSeconds, 11, "live clock did not interpolate")
require(liveClock.snapshot(at: 2).sequence == 1, "accepted sample did not increment sequence")
require(liveClock.snapshot(at: 2).source == .statefulPlayer, "source was not retained")

// Older samples can never rewind a newer observation.
require(sample(&liveClock, position: 12, sampledAt: 3), "newer sample rejected")
require(
    !sample(&liveClock, position: 7, sampledAt: 2.5, receivedAt: 3.1),
    "older sample was accepted"
)
requireNear(liveClock.snapshot(at: 3).positionSeconds, 12, "older sample rewound clock")

// A fresh high-authority stateful-player sample cannot be overwritten by the
// observer or Now Playing. Once it is stale, observer recovery is allowed.
var authorityClock = SpicyLyricsPlaybackClock()
require(sample(&authorityClock, position: 20, sampledAt: 0), "authority seed rejected")
require(
    !sample(
        &authorityClock,
        position: 15,
        sampledAt: 0.2,
        source: .nowPlayingFallback
    ),
    "fresh live sample was overwritten by Now Playing"
)
require(
    !sample(&authorityClock, position: 16, sampledAt: 1, source: .observer),
    "fresh live sample was overwritten by observer"
)
require(
    sample(&authorityClock, position: 23, sampledAt: 2.1, source: .observer),
    "stale live clock did not permit bounded observer recovery"
)
requireNear(authorityClock.snapshot(at: 2.1).positionSeconds, 23, "observer recovery position missing")

// A real pause observation freezes forever; resume continues from the exact
// observed position. Repeating this cycle must not accumulate command latency.
var pauseClock = SpicyLyricsPlaybackClock()
require(sample(&pauseClock, position: 30, sampledAt: 0), "pause seed rejected")
for cycle in 0 ..< 5 {
    let base = Double(cycle) * 10
    let pausePosition = 31 + Double(cycle)
    require(
        sample(&pauseClock, position: pausePosition, sampledAt: base + 1, playing: false),
        "pause sample rejected"
    )
    requireNear(
        pauseClock.snapshot(at: base + 5).positionSeconds,
        pausePosition,
        "paused clock advanced"
    )
    require(
        sample(&pauseClock, position: pausePosition, sampledAt: base + 5, playing: true),
        "resume sample rejected"
    )
    requireNear(
        pauseClock.snapshot(at: base + 6).positionSeconds,
        pausePosition + 1,
        "resume did not continue from observed pause"
    )
}

// A command request alone changes no playback truth.
var commandClock = SpicyLyricsPlaybackClock()
require(sample(&commandClock, position: 40, sampledAt: 0), "command seed rejected")
requireNear(commandClock.snapshot(at: 1).positionSeconds, 41, "pre-command position wrong")
require(commandClock.snapshot(at: 1).isPlaying, "pre-command state wrong")
// No optimistic pause API exists; only a player sample may freeze the clock.
requireNear(commandClock.snapshot(at: 2).positionSeconds, 42, "clock stopped without an observation")

// A requested seek leaves the truthful old clock visible, rejects pre-seek
// samples, then accepts only a sample near the requested target.
var seekClock = SpicyLyricsPlaybackClock()
require(sample(&seekClock, position: 15, sampledAt: 0), "seek seed rejected")
let seekGeneration = seekClock.generation
require(seekClock.requestSeek(to: 70, generation: seekGeneration, at: 1), "seek request rejected")
requireNear(seekClock.snapshot(at: 1).positionSeconds, 16, "seek request changed observed position")
require(
    !sample(&seekClock, position: 16.1, sampledAt: 1.1),
    "pre-seek sample replaced the clock"
)
requireNear(seekClock.snapshot(at: 1.2).positionSeconds, 16.2, "pre-seek rejection stopped truthful clock")
require(sample(&seekClock, position: 70.05, sampledAt: 1.25), "seek confirmation rejected")
requireNear(seekClock.snapshot(at: 1.25).positionSeconds, 70.05, "seek confirmation missing")
require(seekClock.snapshot(at: 1.25).pendingSeekTargetSeconds == nil, "confirmed seek remained pending")

// If Spotify refuses a seek, the bounded deadline eventually permits its real
// position to win again.
var refusedSeekClock = SpicyLyricsPlaybackClock()
require(sample(&refusedSeekClock, position: 10, sampledAt: 0), "refused-seek seed rejected")
require(refusedSeekClock.requestSeek(to: 90, generation: refusedSeekClock.generation, at: 1), "refused seek request rejected")
require(
    sample(&refusedSeekClock, position: 13.1, sampledAt: 3.1),
    "post-timeout actual position was rejected"
)
requireNear(refusedSeekClock.snapshot(at: 3.1).positionSeconds, 13.1, "post-timeout position missing")

// A track transition is an atomic generation boundary. Any response created
// for the previous generation is rejected even if it arrives later.
var trackClock = SpicyLyricsPlaybackClock()
require(sample(&trackClock, position: 80, sampledAt: 0), "track-a seed rejected")
let oldGeneration = trackClock.generation
let newGeneration = trackClock.transition(to: "track-b", at: 1)
require(newGeneration != oldGeneration, "track change did not increment generation")
requireNear(trackClock.snapshot(at: 1).positionSeconds, 0, "track change retained old timeline")
require(
    !sample(
        &trackClock,
        position: 81,
        sampledAt: 1.1,
        track: "track-a",
        generation: oldGeneration
    ),
    "prior-generation sample was accepted"
)
require(
    sample(&trackClock, position: 0.4, sampledAt: 1.2, track: "track-b"),
    "new-generation sample rejected"
)
requireNear(trackClock.snapshot(at: 1.2).positionSeconds, 0.4, "new track position missing")

// Returning to a previously seen track still starts a fresh generation.
let trackBGeneration = trackClock.generation
let returningGeneration = trackClock.transition(to: "track-a", at: 2)
require(returningGeneration != trackBGeneration, "returning track reused an old generation")

// Backgrounding freezes the last real position. Foregrounding cannot advance
// until a fresh stateful-player sample arrives; fallback data may not wake it.
var lifecycleClock = SpicyLyricsPlaybackClock()
require(sample(&lifecycleClock, position: 20, sampledAt: 0), "lifecycle seed rejected")
lifecycleClock.suspend(at: 2)
requireNear(lifecycleClock.snapshot(at: 30).positionSeconds, 22, "background clock advanced")
lifecycleClock.resumeAwaitingFreshSample(at: 30)
require(
    sample(
        &lifecycleClock,
        position: 46,
        sampledAt: 30.1,
        source: .nowPlayingFallback
    ),
    "foreground fallback observation rejected"
)
requireNear(lifecycleClock.snapshot(at: 35).positionSeconds, 46, "fallback woke suspended clock")
require(lifecycleClock.snapshot(at: 35).requiresFreshSample, "fallback cleared live-sample requirement")
require(sample(&lifecycleClock, position: 47, sampledAt: 35.1), "fresh foreground sample rejected")
requireNear(lifecycleClock.snapshot(at: 36.1).positionSeconds, 48, "fresh foreground sample did not resume")
require(!lifecycleClock.snapshot(at: 36.1).requiresFreshSample, "fresh requirement remained set")

// Position is always clamped to the observed duration.
var endClock = SpicyLyricsPlaybackClock()
require(sample(&endClock, position: 179, sampledAt: 0, duration: 180), "end seed rejected")
requireNear(endClock.snapshot(at: 10).positionSeconds, 180, "clock ran beyond duration")

print("Spicy Lyrics authoritative playback clock tests passed")
