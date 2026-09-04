import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func requireNear(_ value: Double, _ expected: Double, tolerance: Double = 0.001, _ message: String) {
    require(abs(value - expected) <= tolerance, "\(message): expected \(expected), got \(value)")
}

private func sample(
    _ clock: inout SpicyLyricsPlaybackClock,
    position: Double,
    at time: Double,
    playing: Bool? = true,
    track: String = "track-a",
    duration: Double = 120
) {
    clock.observe(
        positionSeconds: position,
        durationSeconds: duration,
        playbackRate: 1,
        isPlaying: playing,
        trackIdentifier: track,
        at: time
    )
}

// Duplicate callbacks must not keep resetting a running clock to the same
// position. This is the Spotify 9.1.x behavior that froze the mobile renderer.
var duplicateClock = SpicyLyricsPlaybackClock()
sample(&duplicateClock, position: 10, at: 0)
for tick in 1 ... 5 {
    sample(&duplicateClock, position: 10, at: Double(tick) * 0.2)
}
requireNear(duplicateClock.snapshot(at: 1).positionSeconds, 11, "duplicate callbacks rewound playback")

// A normal rounded player update may catch up, but must never make time move
// backward between updates.
sample(&duplicateClock, position: 11, at: 1.05)
require(duplicateClock.snapshot(at: 1.05).positionSeconds >= 11, "clock moved backward on a normal update")

// Pause freezes at the observed instant and resume continues from there.
var pauseClock = SpicyLyricsPlaybackClock()
sample(&pauseClock, position: 20, at: 0)
sample(&pauseClock, position: 20.5, at: 0.6, playing: false)
let pausedAt = pauseClock.snapshot(at: 0.6).positionSeconds
requireNear(pauseClock.snapshot(at: 4).positionSeconds, pausedAt, "paused clock kept advancing")
sample(&pauseClock, position: pausedAt, at: 4, playing: true)
requireNear(pauseClock.snapshot(at: 5).positionSeconds, pausedAt + 1, "resumed clock did not advance")

var stalePauseClock = SpicyLyricsPlaybackClock()
sample(&stalePauseClock, position: 30, at: 0)
sample(&stalePauseClock, position: 30, at: 2, playing: false)
requireNear(stalePauseClock.snapshot(at: 4).positionSeconds, 32, "stale pause callback rewound the clock")

// Real external seeks in both directions are discontinuities and must win.
var discontinuityClock = SpicyLyricsPlaybackClock()
sample(&discontinuityClock, position: 12, at: 0)
sample(&discontinuityClock, position: 55, at: 0.2)
requireNear(discontinuityClock.snapshot(at: 0.2).positionSeconds, 55, "forward seek was ignored")
sample(&discontinuityClock, position: 8, at: 0.4)
requireNear(discontinuityClock.snapshot(at: 0.4).positionSeconds, 8, "backward seek was ignored")

// Renderer-requested seeks update immediately and ignore the stale pre-seek
// callback Spotify commonly emits before confirming the target.
var requestedSeekClock = SpicyLyricsPlaybackClock()
sample(&requestedSeekClock, position: 15, at: 0)
requestedSeekClock.requestedSeek(to: 70, at: 1)
sample(&requestedSeekClock, position: 15, at: 1.1)
requireNear(requestedSeekClock.snapshot(at: 1.1).positionSeconds, 70.1, "stale callback undid requested seek")
sample(&requestedSeekClock, position: 70.05, at: 1.2)
require(requestedSeekClock.snapshot(at: 1.2).positionSeconds >= 70, "seek confirmation was not accepted")

// A missing Boolean in a later KVC snapshot retains the last observed state.
var optionalStateClock = SpicyLyricsPlaybackClock()
sample(&optionalStateClock, position: 5, at: 0)
sample(&optionalStateClock, position: 5, at: 0.5, playing: nil)
requireNear(optionalStateClock.snapshot(at: 1).positionSeconds, 6, "missing playing state stopped the clock")

// Track changes reset the timeline, and the end of a track is clamped.
var trackClock = SpicyLyricsPlaybackClock()
sample(&trackClock, position: 118, at: 0)
requireNear(trackClock.snapshot(at: 5).positionSeconds, 120, "clock ran past duration")
sample(&trackClock, position: 2, at: 5, track: "track-b", duration: 200)
requireNear(trackClock.snapshot(at: 5).positionSeconds, 2, "track change retained old position")
require(trackClock.snapshot(at: 5).trackIdentifier == "track-b", "track identifier did not update")

print("Spicy Lyrics playback clock regression tests passed")
