import Foundation

enum SpicyLyricsRepeatMode: String, Equatable {
    case off
    case context
    case track
}

/// Stable identity for one Spotify playback. A track URI is always required;
/// playback/session identifiers are used when Spotify exposes them. Missing an
/// optional identifier for one callback does not manufacture a new session.
struct SpicyLyricsPlaybackIdentity: Equatable {
    let trackIdentifier: String
    let playbackIdentifier: String?
    let sessionIdentifier: String?

    init(
        trackIdentifier: String,
        playbackIdentifier: String? = nil,
        sessionIdentifier: String? = nil
    ) {
        self.trackIdentifier = Self.nonEmpty(trackIdentifier) ?? ""
        self.playbackIdentifier = Self.nonEmpty(playbackIdentifier)
        self.sessionIdentifier = Self.nonEmpty(sessionIdentifier)
    }

    var isUsable: Bool { !trackIdentifier.isEmpty }

    func isSamePlayback(as other: Self) -> Bool {
        guard trackIdentifier == other.trackIdentifier else { return false }
        if let playbackIdentifier, let otherID = other.playbackIdentifier {
            return playbackIdentifier == otherID
        }
        if playbackIdentifier == nil,
           other.playbackIdentifier == nil,
           let sessionIdentifier,
           let otherID = other.sessionIdentifier {
            return sessionIdentifier == otherID
        }
        return true
    }

    func mergingMissingValues(from other: Self) -> Self {
        Self(
            trackIdentifier: trackIdentifier,
            playbackIdentifier: playbackIdentifier ?? other.playbackIdentifier,
            sessionIdentifier: sessionIdentifier ?? other.sessionIdentifier
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SpicyLyricsPlaybackRestrictions: Equatable {
    var disallowSeeking = false
    var disallowPausing = false
    var disallowResuming = false
    var disallowSkippingToPreviousTrack = false
    var disallowSkippingToNextTrack = false
    var disallowTogglingShuffle = false
    var disallowTogglingRepeatContext = false
    var disallowTogglingRepeatTrack = false
}

/// One complete read of Spotify 9.1.76's SPTPlayerState. Position and duration
/// are seconds: SPTPlayerState.initWithProtobuf divides the millisecond fields
/// by 1000, while SPTEsperantoPlayer.seekTo: multiplies seconds by 1000 again.
struct SpicyLyricsPlaybackObservation {
    let identity: SpicyLyricsPlaybackIdentity
    let positionSeconds: Double
    let durationSeconds: Double
    let playbackRate: Double
    let isPlaying: Bool
    let isPaused: Bool
    let isLoading: Bool
    let isBuffering: Bool
    let shuffleEnabled: Bool
    let repeatMode: SpicyLyricsRepeatMode
    let restrictions: SpicyLyricsPlaybackRestrictions
    let sourceTimestampSeconds: TimeInterval?
    let observedAtUptimeSeconds: TimeInterval
}

struct SpicyLyricsPlaybackSnapshot {
    let generation: UInt64
    let sequence: UInt64
    let identity: SpicyLyricsPlaybackIdentity?
    let positionSeconds: Double
    let durationSeconds: Double
    let playbackRate: Double
    let isPlaying: Bool
    let isPaused: Bool
    let isLoading: Bool
    let isBuffering: Bool
    let shuffleEnabled: Bool
    let repeatMode: SpicyLyricsRepeatMode
    let restrictions: SpicyLyricsPlaybackRestrictions
    let requiresFreshObservation: Bool

    var isAdvancing: Bool {
        isPlaying && !isPaused && !isLoading && !isBuffering && !requiresFreshObservation
    }
}

/// Deterministic reducer for the renderer's only playback timeline.
///
/// There is deliberately no source arbitration and no optimistic mutation.
/// Observer callbacks and periodic refreshes are merely two triggers that read
/// the same SPTPlayerState object. Commands never change this state; only a
/// later player observation does.
struct SpicyLyricsPlaybackClock {
    private(set) var generation: UInt64 = 0
    private(set) var sequence: UInt64 = 0
    private(set) var identity: SpicyLyricsPlaybackIdentity?

    private var anchorPositionSeconds = 0.0
    private var anchorUptimeSeconds = 0.0
    private var durationSeconds = 0.0
    private var playbackRate = 1.0
    private var isPlaying = false
    private var isPaused = true
    private var isLoading = false
    private var isBuffering = false
    private var shuffleEnabled = false
    private var repeatMode: SpicyLyricsRepeatMode = .off
    private var restrictions = SpicyLyricsPlaybackRestrictions()
    private var lastSourceTimestampSeconds: TimeInterval?
    private var lastObservedAtUptimeSeconds = -Double.greatestFiniteMagnitude
    private var isSuspended = false
    private var requiresFreshObservation = true

    @discardableResult
    mutating func submit(_ observation: SpicyLyricsPlaybackObservation) -> Bool {
        guard observation.identity.isUsable,
              observation.positionSeconds.isFinite,
              observation.durationSeconds.isFinite,
              observation.playbackRate.isFinite,
              observation.observedAtUptimeSeconds.isFinite else {
            return false
        }

        guard observation.observedAtUptimeSeconds + 0.000_001
                >= lastObservedAtUptimeSeconds else {
            return false
        }

        let samePlayback = identity?.isSamePlayback(as: observation.identity) ?? false
        // SPTPlayerState.timestamp is only comparable inside one playback.
        // A new track/session may legitimately use an older timestamp.
        // Equal timestamps remain valid because `position` is a computed live
        // getter and advances between polls even when the state object itself
        // has not been replaced.
        if samePlayback,
           let incomingTimestamp = observation.sourceTimestampSeconds,
           let previousTimestamp = lastSourceTimestampSeconds,
           incomingTimestamp + 0.000_001 < previousTimestamp {
            return false
        }

        if let currentIdentity = identity {
            if !samePlayback {
                beginGeneration(with: observation.identity)
            } else {
                identity = observation.identity.mergingMissingValues(from: currentIdentity)
            }
        } else {
            beginGeneration(with: observation.identity)
        }

        durationSeconds = max(0, observation.durationSeconds)
        anchorPositionSeconds = bounded(observation.positionSeconds)
        anchorUptimeSeconds = observation.observedAtUptimeSeconds
        playbackRate = observation.playbackRate > 0 ? observation.playbackRate : 1
        isPlaying = observation.isPlaying
        isPaused = observation.isPaused
        isLoading = observation.isLoading
        isBuffering = observation.isBuffering
        shuffleEnabled = observation.shuffleEnabled
        repeatMode = observation.repeatMode
        restrictions = observation.restrictions
        lastObservedAtUptimeSeconds = observation.observedAtUptimeSeconds
        if let sourceTimestamp = observation.sourceTimestampSeconds {
            lastSourceTimestampSeconds = max(
                sourceTimestamp,
                lastSourceTimestampSeconds ?? sourceTimestamp
            )
        }
        isSuspended = false
        requiresFreshObservation = false
        incrementSequence()
        return true
    }

    /// Freeze on the last rendered instant before UIKit/WebKit becomes hidden.
    mutating func suspend(at uptimeSeconds: TimeInterval) {
        guard uptimeSeconds.isFinite else { return }
        if identity != nil {
            anchorPositionSeconds = snapshot(at: uptimeSeconds).positionSeconds
            anchorUptimeSeconds = uptimeSeconds
        }
        isSuspended = true
        requiresFreshObservation = true
        incrementSequence()
    }

    /// Foreground does not guess how long audio advanced while hidden. The next
    /// exact SPTPlayerState read releases this gate.
    mutating func resumeAwaitingObservation(at uptimeSeconds: TimeInterval) {
        guard uptimeSeconds.isFinite else { return }
        if identity != nil { anchorUptimeSeconds = uptimeSeconds }
        isSuspended = true
        requiresFreshObservation = true
        incrementSequence()
    }

    func snapshot(at uptimeSeconds: TimeInterval) -> SpicyLyricsPlaybackSnapshot {
        let now = uptimeSeconds.isFinite ? uptimeSeconds : anchorUptimeSeconds
        let canAdvance = identity != nil
            && isPlaying
            && !isPaused
            && !isLoading
            && !isBuffering
            && !isSuspended
            && !requiresFreshObservation
        let elapsed = canAdvance
            ? max(0, now - anchorUptimeSeconds) * playbackRate
            : 0

        return SpicyLyricsPlaybackSnapshot(
            generation: generation,
            sequence: sequence,
            identity: identity,
            positionSeconds: bounded(anchorPositionSeconds + elapsed),
            durationSeconds: durationSeconds,
            playbackRate: playbackRate,
            isPlaying: isPlaying,
            isPaused: isPaused,
            isLoading: isLoading,
            isBuffering: isBuffering,
            shuffleEnabled: shuffleEnabled,
            repeatMode: repeatMode,
            restrictions: restrictions,
            requiresFreshObservation: requiresFreshObservation
        )
    }

    private mutating func beginGeneration(with identity: SpicyLyricsPlaybackIdentity) {
        generation &+= 1
        if generation == 0 { generation = 1 }
        sequence = 0
        self.identity = identity
        anchorPositionSeconds = 0
        durationSeconds = 0
        playbackRate = 1
        isPlaying = false
        isPaused = true
        isLoading = false
        isBuffering = false
        shuffleEnabled = false
        repeatMode = .off
        restrictions = SpicyLyricsPlaybackRestrictions()
        lastSourceTimestampSeconds = nil
        lastObservedAtUptimeSeconds = -Double.greatestFiniteMagnitude
        isSuspended = false
        requiresFreshObservation = true
    }

    private mutating func incrementSequence() {
        sequence &+= 1
        if sequence == 0 { sequence = 1 }
    }

    private func bounded(_ value: Double) -> Double {
        let position = max(0, value)
        return durationSeconds > 0 ? min(position, durationSeconds) : position
    }
}
