import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func requireNear(_ value: Double, _ expected: Double, tolerance: Double = 0.001, _ message: String) {
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

// Spotify's positionAsOfTimestamp is an anchor. A state callback that arrives
// late must be projected to callback time or every fresh lyrics view begins
// behind the audio until another transport event happens to correct it.
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
    "late timestamped callback was not projected forward"
)
requireNear(
    SpicyLyricsPlaybackTimestampProjector.positionSeconds(
        anchorPositionSeconds: 12,
        fallbackPositionSeconds: 12,
        sourceTimestamp: 100,
        callbackTimestamp: 102.5,
        playbackRate: 1,
        isPlaying: false
    ),
    12,
    "paused timestamped state advanced"
)
requireNear(
    SpicyLyricsPlaybackTimestampProjector.positionSeconds(
        anchorPositionSeconds: 12,
        fallbackPositionSeconds: 44,
        sourceTimestamp: 100,
        callbackTimestamp: 500,
        playbackRate: 1,
        isPlaying: true
    ),
    44,
    "unreasonably old timestamp did not use the live fallback"
)

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

// A genuinely newer report can correct a small amount of clock lead. Refusing
// every negative correction made callback jitter accumulate after pauses.
sample(&duplicateClock, position: 11, at: 1.05)
requireNear(duplicateClock.snapshot(at: 1.05).positionSeconds, 11, "fresh report did not correct clock lead")

// Pause freezes at the observed instant and resume continues from there.
var pauseClock = SpicyLyricsPlaybackClock()
sample(&pauseClock, position: 20, at: 0)
sample(&pauseClock, position: 20.5, at: 0.6, playing: false)
let pausedAt = pauseClock.snapshot(at: 0.6).positionSeconds
requireNear(pauseClock.snapshot(at: 4).positionSeconds, pausedAt, "paused clock kept advancing")
sample(&pauseClock, position: pausedAt, at: 4, playing: true)
requireNear(pauseClock.snapshot(at: 5).positionSeconds, pausedAt + 1, "resumed clock did not advance")

// A command accepted by the native transport updates the renderer immediately
// while Spotify's observer catches up with the requested state.
var requestedPlaybackClock = SpicyLyricsPlaybackClock()
sample(&requestedPlaybackClock, position: 40, at: 0)
requestedPlaybackClock.requestedPlaybackState(isPlaying: false, playbackRate: 1, at: 1)
requireNear(requestedPlaybackClock.snapshot(at: 3).positionSeconds, 41, "requested pause did not freeze immediately")
requestedPlaybackClock.requestedPlaybackState(isPlaying: true, playbackRate: 1, at: 3)
requireNear(requestedPlaybackClock.snapshot(at: 4).positionSeconds, 42, "requested resume did not restart immediately")

// The old playing snapshot emitted after a local pause must not restart the
// visual clock. A matching pause snapshot confirms the command and may correct
// the final frozen position.
var requestedPauseClock = SpicyLyricsPlaybackClock()
sample(&requestedPauseClock, position: 30, at: 0)
requestedPauseClock.requestedPlaybackState(isPlaying: false, playbackRate: 1, at: 1)
sample(&requestedPauseClock, position: 31.2, at: 1.1, playing: true)
requireNear(requestedPauseClock.snapshot(at: 1.5).positionSeconds, 31, "stale callback advanced requested pause")
sample(&requestedPauseClock, position: 31.05, at: 1.6, playing: false)
requireNear(requestedPauseClock.snapshot(at: 4).positionSeconds, 31.05, "pause confirmation did not freeze at player position")

// The inverse race happens on resume: a late paused snapshot must not stop the
// optimistic running clock before the matching playing snapshot arrives.
var requestedResumeClock = SpicyLyricsPlaybackClock()
sample(&requestedResumeClock, position: 50, at: 0, playing: false)
requestedResumeClock.requestedPlaybackState(isPlaying: true, playbackRate: 1, at: 1)
sample(&requestedResumeClock, position: 50, at: 1.1, playing: false)
requireNear(requestedResumeClock.snapshot(at: 1.5).positionSeconds, 50.5, "stale callback stopped requested resume")
sample(&requestedResumeClock, position: 50.55, at: 1.6, playing: true)
requireNear(requestedResumeClock.snapshot(at: 2.6).positionSeconds, 51.55, "resume confirmation was not accepted")

var rapidToggleClock = SpicyLyricsPlaybackClock()
sample(&rapidToggleClock, position: 5, at: 0)
rapidToggleClock.requestedPlaybackState(isPlaying: false, playbackRate: 1, at: 1)
rapidToggleClock.requestedPlaybackState(isPlaying: true, playbackRate: 1, at: 1.2)
requireNear(rapidToggleClock.snapshot(at: 2.2).positionSeconds, 7, "rapid pause/resume retained the old request")

// An external pause has no optimistic request, so the first paused position is
// authoritative and removes any extrapolation lead immediately.
var externalPauseClock = SpicyLyricsPlaybackClock()
sample(&externalPauseClock, position: 30, at: 0)
sample(&externalPauseClock, position: 31.4, at: 2, playing: false)
requireNear(externalPauseClock.snapshot(at: 4).positionSeconds, 31.4, "external pause retained extrapolation lead")

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

// Returning from the background replaces the old interpolated position with
// the authoritative system transport clock, regardless of time spent hidden.
var foregroundClock = SpicyLyricsPlaybackClock()
sample(&foregroundClock, position: 20, at: 0)
foregroundClock.reanchor(
    positionSeconds: 47.25,
    durationSeconds: 180,
    playbackRate: 1,
    isPlaying: true,
    trackIdentifier: "track-a",
    at: 30
)
requireNear(foregroundClock.snapshot(at: 30).positionSeconds, 47.25, "foreground reanchor kept stale hidden time")
requireNear(foregroundClock.snapshot(at: 31).positionSeconds, 48.25, "foreground reanchor did not resume")

foregroundClock.reanchor(
    positionSeconds: 61,
    durationSeconds: 180,
    playbackRate: 1,
    isPlaying: false,
    trackIdentifier: "track-a",
    at: 40
)
requireNear(foregroundClock.snapshot(at: 50).positionSeconds, 61, "paused foreground reanchor advanced")

print("Spicy Lyrics playback clock regression tests passed")
