import Foundation

struct SpicyLyricsPlaybackUnitNormalizer {
    private(set) var positionScale: Double?

    mutating func durationSeconds(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return 0 }
        return raw > 10_000 ? raw / 1000 : raw
    }

    mutating func positionSeconds(
        _ raw: Double,
        durationSeconds: Double,
        referenceSeconds: Double?
    ) -> Double {
        guard raw.isFinite, raw > 0 else { return 0 }
        if let scale = positionScale { return raw * scale }
        guard durationSeconds > 0 else {
            let scale = raw > 10_000 ? 0.001 : 1
            positionScale = scale
            return raw * scale
        }

        let secondsCandidate = raw
        let millisecondsCandidate = raw / 1000
        let tolerance = max(2, durationSeconds * 0.03)
        let secondsFits = secondsCandidate <= durationSeconds + tolerance
        let millisecondsFits = millisecondsCandidate <= durationSeconds + tolerance

        if secondsFits && !millisecondsFits {
            positionScale = 1
            return secondsCandidate
        }
        if millisecondsFits && !secondsFits {
            positionScale = 0.001
            return millisecondsCandidate
        }
        if secondsFits && millisecondsFits {
            if let referenceSeconds {
                let secondsError = abs(secondsCandidate - referenceSeconds)
                let millisecondsError = abs(millisecondsCandidate - referenceSeconds)
                if millisecondsError + 0.5 < secondsError {
                    positionScale = 0.001
                    return millisecondsCandidate
                }
                if secondsError + 0.5 < millisecondsError {
                    positionScale = 1
                    return secondsCandidate
                }
            }
            // Do not lock an ambiguous early sample. A later report or the
            // system transport reference will establish the unit.
            return secondsCandidate
        }

        positionScale = 0.001
        return millisecondsCandidate
    }
}

/// Projects Spotify's timestamped state to the instant its callback reached
/// the app. `positionAsOfTimestamp` is an anchor, not the current position.
/// Ignoring the timestamp makes lyrics start late by however long the state sat
/// in Spotify's observer pipeline, then lets a late callback undo a correct
/// pause/resume or track-change re-anchor.
struct SpicyLyricsPlaybackTimestampProjector {
    static func positionSeconds(
        anchorPositionSeconds: Double?,
        fallbackPositionSeconds: Double,
        sourceTimestamp: TimeInterval?,
        callbackTimestamp: TimeInterval,
        playbackRate: Double,
        isPlaying: Bool?
    ) -> Double {
        let fallback = fallbackPositionSeconds.isFinite
            ? max(0, fallbackPositionSeconds)
            : 0
        guard let anchorPositionSeconds,
              anchorPositionSeconds.isFinite else { return fallback }

        let anchor = max(0, anchorPositionSeconds)
        guard isPlaying == true,
              let sourceTimestamp,
              sourceTimestamp.isFinite,
              callbackTimestamp.isFinite else { return anchor }

        let age = callbackTimestamp - sourceTimestamp
        // A negative age is a clock mismatch. Very old state objects are also
        // unsafe to extrapolate (foreground recovery uses Now Playing instead).
        guard age >= 0, age <= 300 else { return fallback }
        let rate = playbackRate.isFinite && playbackRate > 0 ? playbackRate : 1
        return anchor + age * rate
    }
}

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
    private var pendingPlaybackState: Bool?
    private var pendingPlaybackDeadlineSeconds: Double = 0

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

        // A transport command updates the renderer immediately. Spotify can
        // publish one or more snapshots containing the old playing state
        // before the command reaches its player core, so those stale snapshots
        // must not restart a just-paused lyric clock (or stop a just-resumed
        // one). The first matching snapshot confirms the request.
        if let requestedPlaying = pendingPlaybackState,
           uptimeSeconds <= pendingPlaybackDeadlineSeconds {
            guard reportedPlaying == requestedPlaying else {
                playbackRate = rate
                isPlaying = requestedPlaying
                return
            }
            pendingPlaybackState = nil
            pendingPlaybackDeadlineSeconds = 0
        } else {
            pendingPlaybackState = nil
            pendingPlaybackDeadlineSeconds = 0
        }

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

        let repeatedReport = lastReportedPositionSeconds != nil
            && abs(reportedDelta) < 0.001

        if isDiscontinuity {
            // A real forward/backward seek must be accepted immediately.
            anchorPositionSeconds = position
        } else if nextPlaying {
            // Duplicate callbacks carry the position at which their state
            // object was created, so keep interpolating through them. A fresh
            // moving report is authoritative in both directions; accepting a
            // small negative correction prevents pause/callback jitter from
            // accumulating into lyrics that run ahead of the audio.
            anchorPositionSeconds = repeatedReport ? predictedPosition : position
        } else {
            // Once Spotify confirms a pause, its frozen position is the source
            // of truth. Keeping the prediction here made every delayed pause
            // permanently add that delay to the lyrics clock.
            anchorPositionSeconds = position
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

    /// Replaces the interpolation anchor with an authoritative transport
    /// snapshot. This is used when the app returns from the background: WebKit
    /// and native timers may have been suspended for different lengths of time,
    /// so advancing the old anchor by wall time is not valid.
    mutating func reanchor(
        positionSeconds rawPosition: Double,
        durationSeconds rawDuration: Double,
        playbackRate rawRate: Double,
        isPlaying: Bool,
        trackIdentifier: String?,
        at uptimeSeconds: Double
    ) {
        guard rawPosition.isFinite, rawDuration.isFinite, rawRate.isFinite, uptimeSeconds.isFinite else {
            return
        }
        reset(
            positionSeconds: max(0, rawPosition),
            durationSeconds: max(0, rawDuration),
            playbackRate: rawRate > 0 ? rawRate : max(0.1, playbackRate),
            isPlaying: isPlaying,
            trackIdentifier: trackIdentifier?.isEmpty == false ? trackIdentifier : self.trackIdentifier,
            at: uptimeSeconds
        )
    }

    mutating func requestedPlaybackState(
        isPlaying: Bool,
        playbackRate rawRate: Double,
        at uptimeSeconds: Double
    ) {
        guard uptimeSeconds.isFinite, rawRate.isFinite else { return }
        pendingPlaybackState = nil
        pendingPlaybackDeadlineSeconds = 0
        reconcilePlaybackState(
            isPlaying: isPlaying,
            playbackRate: rawRate,
            at: uptimeSeconds
        )
        pendingPlaybackState = isPlaying
        pendingPlaybackDeadlineSeconds = uptimeSeconds + 4
    }

    mutating func reconcilePlaybackState(
        isPlaying: Bool,
        playbackRate rawRate: Double,
        at uptimeSeconds: Double
    ) {
        guard uptimeSeconds.isFinite, rawRate.isFinite else { return }

        if let requestedPlaying = pendingPlaybackState,
           uptimeSeconds <= pendingPlaybackDeadlineSeconds {
            guard isPlaying == requestedPlaying else { return }
            pendingPlaybackState = nil
            pendingPlaybackDeadlineSeconds = 0
        } else if pendingPlaybackState != nil {
            pendingPlaybackState = nil
            pendingPlaybackDeadlineSeconds = 0
        }

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
        pendingPlaybackState = nil
        pendingPlaybackDeadlineSeconds = 0
    }

    private func bounded(_ position: Double) -> Double {
        durationSeconds > 0
            ? min(max(0, position), durationSeconds)
            : max(0, position)
    }
}
