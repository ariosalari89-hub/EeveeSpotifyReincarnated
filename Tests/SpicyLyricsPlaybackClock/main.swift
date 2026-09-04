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

private func observation(
    track: String = "track-a",
    playback: String? = "playback-a",
    session: String? = "session-a",
    position: Double,
    duration: Double = 180,
    rate: Double = 1,
    playing: Bool = true,
    paused: Bool = false,
    loading: Bool = false,
    buffering: Bool = false,
    shuffle: Bool = false,
    repeatMode: SpicyLyricsRepeatMode = .off,
    sourceTimestamp: Double? = nil,
    observedAt: Double
) -> SpicyLyricsPlaybackObservation {
    SpicyLyricsPlaybackObservation(
        identity: SpicyLyricsPlaybackIdentity(
            trackIdentifier: track,
            playbackIdentifier: playback,
            sessionIdentifier: session
        ),
        positionSeconds: position,
        durationSeconds: duration,
        playbackRate: rate,
        isPlaying: playing,
        isPaused: paused,
        isLoading: loading,
        isBuffering: buffering,
        shuffleEnabled: shuffle,
        repeatMode: repeatMode,
        restrictions: SpicyLyricsPlaybackRestrictions(),
        sourceTimestampSeconds: sourceTimestamp,
        observedAtUptimeSeconds: observedAt
    )
}

// Initial observation creates one generation and advances from its exact
// receipt time with no artificial lead.
var clock = SpicyLyricsPlaybackClock()
require(clock.submit(observation(position: 10, sourceTimestamp: 100, observedAt: 1)), "initial state rejected")
require(clock.generation == 1, "initial generation missing")
requireNear(clock.snapshot(at: 2).positionSeconds, 11, "playing position did not advance")

// Equal source timestamps are valid because SPTPlayerState.position is a live
// computed getter. An older callback inside the same playback is rejected.
require(clock.submit(observation(position: 11.2, sourceTimestamp: 100, observedAt: 2.2)), "equal timestamp poll rejected")
require(!clock.submit(observation(position: 9, sourceTimestamp: 99, observedAt: 2.3)), "older state rewound playback")
requireNear(clock.snapshot(at: 2.3).positionSeconds, 11.3, "stale callback changed anchor")

// A new track/session is an atomic boundary even if its timestamp is lower.
require(clock.submit(observation(
    track: "track-b",
    playback: "playback-b",
    session: "session-b",
    position: 0.4,
    sourceTimestamp: 2,
    observedAt: 3
)), "new playback with reset timestamp rejected")
require(clock.generation == 2, "track transition did not increment generation")
require(clock.snapshot(at: 3).identity?.trackIdentifier == "track-b", "track identity did not swap")
requireNear(clock.snapshot(at: 3).positionSeconds, 0.4, "new track retained old position")

// Missing optional IDs on a callback do not manufacture another generation.
let stableGeneration = clock.generation
require(clock.submit(observation(
    track: "track-b",
    playback: nil,
    session: nil,
    position: 1,
    sourceTimestamp: 3,
    observedAt: 3.6
)), "partial identity observation rejected")
require(clock.generation == stableGeneration, "partial identity split one playback")

// Pause/resume is observation-only and never accumulates command latency.
var pauseClock = SpicyLyricsPlaybackClock()
for cycle in 0 ..< 100 {
    let base = Double(cycle) * 10
    let position = 20 + Double(cycle)
    require(pauseClock.submit(observation(
        position: position,
        playing: false,
        paused: true,
        sourceTimestamp: base + 1,
        observedAt: base + 1
    )), "pause observation rejected")
    requireNear(pauseClock.snapshot(at: base + 8).positionSeconds, position, "pause drifted")
    require(pauseClock.submit(observation(
        position: position,
        playing: true,
        paused: false,
        sourceTimestamp: base + 8,
        observedAt: base + 8
    )), "resume observation rejected")
    requireNear(pauseClock.snapshot(at: base + 9).positionSeconds, position + 1, "resume anchor was offset")
}

// Buffering/loading freeze the clock until the next authoritative observation.
var stallClock = SpicyLyricsPlaybackClock()
require(stallClock.submit(observation(position: 30, buffering: true, observedAt: 0)), "buffer state rejected")
requireNear(stallClock.snapshot(at: 50).positionSeconds, 30, "buffering clock advanced")
require(stallClock.submit(observation(position: 30.5, loading: true, observedAt: 50)), "loading state rejected")
requireNear(stallClock.snapshot(at: 90).positionSeconds, 30.5, "loading clock advanced")

// Lifecycle never estimates hidden time. Only a new player observation clears
// the foreground freshness gate.
var lifecycleClock = SpicyLyricsPlaybackClock()
require(lifecycleClock.submit(observation(position: 40, observedAt: 0)), "lifecycle seed rejected")
lifecycleClock.suspend(at: 2)
requireNear(lifecycleClock.snapshot(at: 100).positionSeconds, 42, "hidden clock advanced")
require(lifecycleClock.snapshot(at: 100).requiresFreshObservation, "hidden state did not require resync")
require(lifecycleClock.submit(observation(position: 60, observedAt: 80)), "hidden observation rejected")
requireNear(lifecycleClock.snapshot(at: 99).positionSeconds, 60, "hidden observation was extrapolated")
require(lifecycleClock.snapshot(at: 99).requiresFreshObservation, "hidden observation released gate")
lifecycleClock.resumeAwaitingObservation(at: 100)
requireNear(lifecycleClock.snapshot(at: 110).positionSeconds, 60, "foreground guessed hidden progress")
require(lifecycleClock.submit(observation(position: 75, observedAt: 100.1)), "fresh foreground state rejected")
requireNear(lifecycleClock.snapshot(at: 101.1).positionSeconds, 76, "fresh foreground state did not resume")

// Shuffle/repeat/restrictions are part of the same immutable snapshot.
var optionClock = SpicyLyricsPlaybackClock()
var restrictions = SpicyLyricsPlaybackRestrictions()
restrictions.disallowSeeking = true
let optionObservation = SpicyLyricsPlaybackObservation(
    identity: SpicyLyricsPlaybackIdentity(trackIdentifier: "options"),
    positionSeconds: 5,
    durationSeconds: 60,
    playbackRate: 1,
    isPlaying: true,
    isPaused: false,
    isLoading: false,
    isBuffering: false,
    shuffleEnabled: true,
    repeatMode: .track,
    restrictions: restrictions,
    sourceTimestampSeconds: nil,
    observedAtUptimeSeconds: 0
)
require(optionClock.submit(optionObservation), "option observation rejected")
let optionSnapshot = optionClock.snapshot(at: 0)
require(optionSnapshot.shuffleEnabled, "shuffle state missing")
require(optionSnapshot.repeatMode == .track, "repeat state missing")
require(optionSnapshot.restrictions.disallowSeeking, "restrictions missing")

// Position is always clamped to the observed duration.
var endClock = SpicyLyricsPlaybackClock()
require(endClock.submit(observation(position: 179, duration: 180, observedAt: 0)), "end seed rejected")
requireNear(endClock.snapshot(at: 20).positionSeconds, 180, "clock advanced beyond duration")

print("Spicy Lyrics deterministic playback clock tests passed")
