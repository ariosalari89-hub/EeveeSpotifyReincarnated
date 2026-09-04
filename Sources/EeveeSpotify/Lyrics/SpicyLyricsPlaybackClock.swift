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
            return secondsCandidate
        }

        positionScale = 0.001
        return millisecondsCandidate
    }
}

/// Projects a timestamped fallback state to the instant it was received. This
/// is retained for observer and Now Playing recovery only; the stateful player
/// position getter already reports seconds on the live player clock.
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
        guard age >= 0, age <= 300 else { return fallback }
        let rate = playbackRate.isFinite && playbackRate > 0 ? playbackRate : 1
        return anchor + age * rate
    }
}

enum SpicyLyricsPlaybackSampleSource: Int {
    case nowPlayingFallback = 0
    case observer = 1
    case statefulPlayer = 2

    var rendererValue: String {
        switch self {
        case .nowPlayingFallback: return "nowPlayingFallback"
        case .observer: return "observer"
        case .statefulPlayer: return "statefulPlayer"
        }
    }
}

/// A position and discrete-state observation from one native clock domain.
/// `sampledAtUptimeSeconds` identifies the instant represented by `position`;
/// `receivedAtUptimeSeconds` is used only to determine source freshness.
struct SpicyLyricsPlaybackSample {
    let generation: UInt64
    let positionSeconds: Double
    let durationSeconds: Double
    let playbackRate: Double
    let isPlaying: Bool
    let trackIdentifier: String?
    let source: SpicyLyricsPlaybackSampleSource
    let sampledAtUptimeSeconds: Double
    let receivedAtUptimeSeconds: Double
}

struct SpicyLyricsPlaybackClockSnapshot {
    let generation: UInt64
    let sequence: UInt64
    let positionSeconds: Double
    let durationSeconds: Double
    let playbackRate: Double
    let isPlaying: Bool
    let trackIdentifier: String?
    let source: SpicyLyricsPlaybackSampleSource?
    let freshnessSeconds: Double
    let requiresFreshSample: Bool
    let pendingSeekTargetSeconds: Double?
}

/// The one native playback clock used by the full-screen renderer.
///
/// Normal operation accepts position only from the live stateful-player API.
/// Observer and Now Playing samples may seed or recover the clock, but cannot
/// overwrite a fresh higher-authority sample. Transport commands never mutate
/// observed position or play state: a later player sample must confirm them.
struct SpicyLyricsPlaybackClock {
    static let higherAuthorityFreshnessSeconds: Double = 2
    static let seekConfirmationToleranceSeconds: Double = 1.5
    static let seekConfirmationTimeoutSeconds: Double = 2

    private(set) var generation: UInt64 = 0
    private(set) var sequence: UInt64 = 0
    private(set) var trackIdentifier: String?
    private(set) var hasAnchor = false

    private var anchorPositionSeconds: Double = 0
    private var anchorUptimeSeconds: Double = 0
    private var durationSeconds: Double = 0
    private var playbackRate: Double = 1
    private var isPlaying = false
    private var source: SpicyLyricsPlaybackSampleSource?
    private var lastSampledAtUptimeSeconds: Double = -.greatestFiniteMagnitude
    private var lastReceivedAtUptimeSeconds: Double = -.greatestFiniteMagnitude
    private var isSuspended = false
    private var requiresFreshSample = false

    private var pendingSeekTargetSeconds: Double?
    private var pendingSeekGeneration: UInt64?
    private var pendingSeekDeadlineSeconds: Double = 0

    /// Establishes the identity boundary before samples are submitted. A late
    /// sample carries its original generation and therefore cannot switch the
    /// clock back to the previous song.
    @discardableResult
    mutating func transition(
        to rawTrackIdentifier: String?,
        at uptimeSeconds: Double
    ) -> UInt64 {
        guard uptimeSeconds.isFinite else { return generation }
        let incoming = normalizedTrackIdentifier(rawTrackIdentifier)

        if generation == 0 {
            generation = 1
            trackIdentifier = incoming
            resetTimeline(at: uptimeSeconds)
            return generation
        }

        // A transient nil identifier is not a new track. The host will call us
        // again as soon as Spotify exposes the canonical URI.
        guard let incoming else { return generation }
        guard incoming != trackIdentifier else { return generation }

        generation &+= 1
        if generation == 0 { generation = 1 }
        trackIdentifier = incoming
        resetTimeline(at: uptimeSeconds)
        return generation
    }

    /// Accepts a real player observation. Returns false when it was stale,
    /// belonged to another track generation, lost source arbitration, or was a
    /// pre-seek position that would undo a command still awaiting confirmation.
    @discardableResult
    mutating func submit(_ sample: SpicyLyricsPlaybackSample) -> Bool {
        guard sample.positionSeconds.isFinite,
              sample.durationSeconds.isFinite,
              sample.playbackRate.isFinite,
              sample.sampledAtUptimeSeconds.isFinite,
              sample.receivedAtUptimeSeconds.isFinite,
              sample.receivedAtUptimeSeconds >= sample.sampledAtUptimeSeconds,
              sample.generation == generation else { return false }

        let incomingTrack = normalizedTrackIdentifier(sample.trackIdentifier)
        if let incomingTrack,
           let trackIdentifier,
           incomingTrack != trackIdentifier {
            return false
        }

        if hasAnchor,
           sample.sampledAtUptimeSeconds + 0.000_001 < lastSampledAtUptimeSeconds {
            return false
        }

        if let currentSource = source,
           currentSource.rawValue > sample.source.rawValue,
           sample.receivedAtUptimeSeconds - lastReceivedAtUptimeSeconds
               < Self.higherAuthorityFreshnessSeconds {
            return false
        }

        if let target = pendingSeekTargetSeconds,
           pendingSeekGeneration == generation,
           sample.receivedAtUptimeSeconds <= pendingSeekDeadlineSeconds {
            guard abs(sample.positionSeconds - target)
                    <= Self.seekConfirmationToleranceSeconds else {
                return false
            }
            clearPendingSeek()
        } else if pendingSeekTargetSeconds != nil {
            clearPendingSeek()
        }

        let rate = sample.playbackRate > 0 ? sample.playbackRate : max(0.1, playbackRate)
        let duration = max(0, sample.durationSeconds)
        if duration > 0 { durationSeconds = duration }

        anchorPositionSeconds = bounded(max(0, sample.positionSeconds))
        anchorUptimeSeconds = sample.sampledAtUptimeSeconds
        playbackRate = rate
        isPlaying = sample.isPlaying
        source = sample.source
        lastSampledAtUptimeSeconds = sample.sampledAtUptimeSeconds
        lastReceivedAtUptimeSeconds = sample.receivedAtUptimeSeconds
        hasAnchor = true
        sequence &+= 1
        if sequence == 0 { sequence = 1 }

        // A foreground transition stays frozen until the real stateful player
        // clock is sampled. A fallback can be displayed, but cannot restart a
        // timeline that may have been suspended for an arbitrary interval.
        if requiresFreshSample && sample.source == .statefulPlayer {
            requiresFreshSample = false
            isSuspended = false
        } else if !requiresFreshSample {
            isSuspended = false
        }
        return true
    }

    /// Records a seek request without claiming the player has already moved.
    /// Stale samples near the old position are rejected until Spotify reports
    /// the target or the bounded confirmation period expires.
    @discardableResult
    mutating func requestSeek(
        to rawPositionSeconds: Double,
        generation requestedGeneration: UInt64,
        at uptimeSeconds: Double
    ) -> Bool {
        guard rawPositionSeconds.isFinite,
              uptimeSeconds.isFinite,
              requestedGeneration == generation,
              hasAnchor else { return false }
        pendingSeekTargetSeconds = bounded(max(0, rawPositionSeconds))
        pendingSeekGeneration = generation
        pendingSeekDeadlineSeconds = uptimeSeconds + Self.seekConfirmationTimeoutSeconds
        return true
    }

    /// Freezes interpolation immediately when the app is no longer active.
    mutating func suspend(at uptimeSeconds: Double) {
        guard uptimeSeconds.isFinite else { return }
        if hasAnchor {
            anchorPositionSeconds = snapshot(at: uptimeSeconds).positionSeconds
            anchorUptimeSeconds = uptimeSeconds
        }
        isSuspended = true
        requiresFreshSample = true
    }

    /// Keeps the timeline frozen after foregrounding until a new live player
    /// sample is accepted.
    mutating func resumeAwaitingFreshSample(at uptimeSeconds: Double) {
        guard uptimeSeconds.isFinite else { return }
        if hasAnchor { anchorUptimeSeconds = uptimeSeconds }
        isSuspended = true
        requiresFreshSample = true
    }

    func snapshot(at uptimeSeconds: Double) -> SpicyLyricsPlaybackClockSnapshot {
        let safeNow = uptimeSeconds.isFinite ? uptimeSeconds : anchorUptimeSeconds
        let canAdvance = hasAnchor && isPlaying && !isSuspended && !requiresFreshSample
        let elapsed = canAdvance
            ? max(0, safeNow - anchorUptimeSeconds) * playbackRate
            : 0
        let freshness = lastReceivedAtUptimeSeconds.isFinite
            ? max(0, safeNow - lastReceivedAtUptimeSeconds)
            : .greatestFiniteMagnitude

        return SpicyLyricsPlaybackClockSnapshot(
            generation: generation,
            sequence: sequence,
            positionSeconds: bounded(anchorPositionSeconds + elapsed),
            durationSeconds: durationSeconds,
            playbackRate: playbackRate,
            isPlaying: isPlaying,
            trackIdentifier: trackIdentifier,
            source: source,
            freshnessSeconds: freshness,
            requiresFreshSample: requiresFreshSample,
            pendingSeekTargetSeconds: pendingSeekGeneration == generation
                ? pendingSeekTargetSeconds
                : nil
        )
    }

    private mutating func resetTimeline(at uptimeSeconds: Double) {
        sequence = 0
        hasAnchor = false
        anchorPositionSeconds = 0
        anchorUptimeSeconds = uptimeSeconds
        durationSeconds = 0
        playbackRate = 1
        isPlaying = false
        source = nil
        lastSampledAtUptimeSeconds = -.greatestFiniteMagnitude
        lastReceivedAtUptimeSeconds = -.greatestFiniteMagnitude
        isSuspended = false
        requiresFreshSample = false
        clearPendingSeek()
    }

    private mutating func clearPendingSeek() {
        pendingSeekTargetSeconds = nil
        pendingSeekGeneration = nil
        pendingSeekDeadlineSeconds = 0
    }

    private func normalizedTrackIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func bounded(_ position: Double) -> Double {
        durationSeconds > 0
            ? min(max(0, position), durationSeconds)
            : max(0, position)
    }
}
