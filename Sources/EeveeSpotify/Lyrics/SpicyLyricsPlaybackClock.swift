import Foundation

struct SpicyLyricsPlaybackClockSnapshot {
    let positionSeconds: Double
    let durationSeconds: Double
    let playbackRate: Double
    let isPlaying: Bool
    let trackIdentifier: String?
}

/// A monotonic media clock built from Spotify's state snapshots.
///
/// Spotify 9.1.x can repeatedly publish a state object whose `position` is the
/// position at which that object was created. Treating every callback as a new
/// clock anchor makes the UI jump back to the same instant several times a
/// second. This model accepts real discontinuities (seeks and track changes)
/// while ignoring those duplicate, stale positions between authoritative
/// updates.
struct SpicyLyricsPlaybackClock {
    private(set) var hasAnchor = false
    private(set) var trackIdentifier: String?

    private var anchorPositionSeconds: Double = 0
    private var anchorUptimeSeconds: Double = 0
    private var durationSeconds: Double = 0
    private var playbackRate: Double = 1
    private var isPlaying = false

    private var lastReportedPositionSeconds: Double?
    private var lastReportUptimeSeconds: Double = 0
    private var pendingSeekTargetSeconds: Double?
    private var pendingSeekDeadlineSeconds: Double = 0

    mutating func observe(
        positionSeconds rawPosition: Double,
        durationSeconds rawDuration: Double,
        playbackRate rawRate: Double,
        isPlaying reportedPlaying: Bool?,
        trackIdentifier reportedTrackIdentifier: String?,
        at uptimeSeconds: Double
    ) {
        guard rawPosition.isFinite, rawDuration.isFinite, rawRate.isFinite, uptimeSeconds.isFinite else {
            return
        }

        let position = max(0, rawPosition)
        let duration = max(0, rawDuration)
        let rate = rawRate > 0 ? rawRate : max(0.1, playbackRate)
        let incomingTrack = reportedTrackIdentifier?.isEmpty == false
            ? reportedTrackIdentifier
            : nil
        let changedTrack = incomingTrack != nil
            && trackIdentifier != nil
            && incomingTrack != trackIdentifier

        if !hasAnchor || changedTrack {
            reset(
                positionSeconds: position,
                durationSeconds: duration,
                playbackRate: rate,
                isPlaying: reportedPlaying ?? false,
                trackIdentifier: incomingTrack ?? trackIdentifier,
                at: uptimeSeconds
            )
            return
        }

        if let incomingTrack { trackIdentifier = incomingTrack }
        if duration > 0 { durationSeconds = duration }

        let nextPlaying = reportedPlaying ?? isPlaying
        let predictedPosition = snapshot(at: uptimeSeconds).positionSeconds

        // A seek requested by this renderer is reflected immediately. Spotify
        // can emit one or more callbacks carrying the pre-seek position, so
        // ignore those until the target arrives or the short deadline expires.
        if let pendingTarget = pendingSeekTargetSeconds,
           uptimeSeconds <= pendingSeekDeadlineSeconds {
            if abs(position - pendingTarget) <= 1.25 {
                anchorPositionSeconds = position
                anchorUptimeSeconds = uptimeSeconds
                pendingSeekTargetSeconds = nil
                lastReportedPositionSeconds = position
                lastReportUptimeSeconds = uptimeSeconds
            }
            playbackRate = rate
            isPlaying = nextPlaying
            return
        }
        pendingSeekTargetSeconds = nil

        let reportedDelta = lastReportedPositionSeconds.map { position - $0 } ?? 0
        let reportInterval = max(0, uptimeSeconds - lastReportUptimeSeconds)
        let plausibleForwardAdvance = max(
            1.5,
            reportInterval * max(rate, playbackRate) + 1.25
        )
        let isDiscontinuity = reportedDelta < -0.75
            || reportedDelta > plausibleForwardAdvance

        if isDiscontinuity {
            // A real forward/backward seek must be accepted immediately.
            anchorPositionSeconds = position
        } else if nextPlaying {
            // Never let a duplicate state callback rewind a running clock.
            // A newer position that is ahead still corrects drift immediately.
            anchorPositionSeconds = max(predictedPosition, position)
        } else {
            // Pausing can arrive with a slightly old rounded position. Preserve
            // at most the current prediction to prevent a visible back-jump.
            let lag = predictedPosition - position
            let repeatedStalePosition = lastReportedPositionSeconds != nil
                && abs(reportedDelta) < 0.001
            anchorPositionSeconds = repeatedStalePosition || (lag > 0 && lag < 1.25)
                ? predictedPosition
                : position
        }

        anchorUptimeSeconds = uptimeSeconds
        playbackRate = rate
        isPlaying = nextPlaying
        lastReportedPositionSeconds = position
        lastReportUptimeSeconds = uptimeSeconds
    }

    mutating func requestedSeek(to rawPosition: Double, at uptimeSeconds: Double) {
        guard rawPosition.isFinite, uptimeSeconds.isFinite else { return }
        let target = bounded(max(0, rawPosition))
        hasAnchor = true
        anchorPositionSeconds = target
        anchorUptimeSeconds = uptimeSeconds
        pendingSeekTargetSeconds = target
        pendingSeekDeadlineSeconds = uptimeSeconds + 2
    }

    mutating func reconcilePlaybackState(
        isPlaying: Bool,
        playbackRate rawRate: Double,
        at uptimeSeconds: Double
    ) {
        guard uptimeSeconds.isFinite, rawRate.isFinite else { return }
        let currentPosition = snapshot(at: uptimeSeconds).positionSeconds
        anchorPositionSeconds = currentPosition
        anchorUptimeSeconds = uptimeSeconds
        playbackRate = rawRate > 0 ? rawRate : max(0.1, playbackRate)
        self.isPlaying = isPlaying
    }

    func snapshot(at uptimeSeconds: Double) -> SpicyLyricsPlaybackClockSnapshot {
        let elapsed = hasAnchor && isPlaying
            ? max(0, uptimeSeconds - anchorUptimeSeconds) * playbackRate
            : 0
        return SpicyLyricsPlaybackClockSnapshot(
            positionSeconds: bounded(anchorPositionSeconds + elapsed),
            durationSeconds: durationSeconds,
            playbackRate: playbackRate,
            isPlaying: isPlaying,
            trackIdentifier: trackIdentifier
        )
    }

    private mutating func reset(
        positionSeconds: Double,
        durationSeconds: Double,
        playbackRate: Double,
        isPlaying: Bool,
        trackIdentifier: String?,
        at uptimeSeconds: Double
    ) {
        hasAnchor = true
        self.trackIdentifier = trackIdentifier
        anchorPositionSeconds = positionSeconds
        anchorUptimeSeconds = uptimeSeconds
        self.durationSeconds = durationSeconds
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
        lastReportedPositionSeconds = positionSeconds
        lastReportUptimeSeconds = uptimeSeconds
        pendingSeekTargetSeconds = nil
        pendingSeekDeadlineSeconds = 0
    }

    private func bounded(_ position: Double) -> Double {
        durationSeconds > 0
            ? min(max(0, position), durationSeconds)
            : max(0, position)
    }
}
