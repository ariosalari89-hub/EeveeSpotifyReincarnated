import Foundation
import MediaPlayer
import ObjectiveC.runtime
import UIKit
import EeveeSpotifyC

/// Native half of the local renderer's playback bridge. The live Spotify
/// stateful player is the normal position source; observer and Now Playing
/// values are bounded fallbacks only.
final class SpicyLyricsPlaybackBridge {
    static let shared = SpicyLyricsPlaybackBridge()

    private struct NativeObservation {
        let positionSeconds: Double
        let durationSeconds: Double
        let playbackRate: Double
        let isPlaying: Bool
        let trackIdentifier: String?
        let shuffleEnabled: Bool?
        let repeatMode: String?
        let sampledAtUptimeSeconds: Double
        let receivedAtUptimeSeconds: Double
        let source: SpicyLyricsPlaybackSampleSource
    }

    private let queue = DispatchQueue(label: "com.eevee.spicylyrics.playback")
    private weak var player: AnyObject?
    private var clock = SpicyLyricsPlaybackClock()
    private var playbackUnits = SpicyLyricsPlaybackUnitNormalizer()
    private var lastObserverSourceTimestamp: TimeInterval?
    private var lastObserverTrackIdentifier: String?
    private var shuffleEnabled = false
    private var repeatMode = "off"
    private var lastDiagnosticStamp = 0.0
    private var lastDiagnosticPlaying: Bool?
    private var lastDiagnosticTrackIdentifier: String?

    /// Desktop Spicy Lyrics intentionally paints about one display beat ahead
    /// of the raw transport clock. It is applied once in the native payload and
    /// never again by JavaScript.
    private static let perceptualLeadSeconds = 0.1

    private init() {}

    func processStateChange(player: AnyObject, state: AnyObject) {
        let positionRaw = (safeRead(state, key: "position") as? NSNumber)?.doubleValue ?? 0
        let timestampedPositionRaw = (safeRead(state, key: "positionAsOfTimestamp") as? NSNumber)?.doubleValue
        let durationRaw = (safeRead(state, key: "duration") as? NSNumber)?.doubleValue ?? 0
        let rate = (safeRead(state, key: "playbackSpeed") as? NSNumber)?.doubleValue ?? 1
        let playing = safeBool(state, key: "isPlaying")
        let sourceTimestamp = dateTimestamp(safeRead(state, key: "timestamp"))
        let callbackTimestamp = Date().timeIntervalSince1970
        let observerTrack = extractURI(from: safeRead(state, key: "track") as AnyObject?)
            .flatMap { spotifyTrackID(from: $0) }
        let liveTrack = Thread.isMainThread
            ? nonEmpty(statefulPlayer?.currentTrack()?.trackIdentifier)
            : nil
        let nowPlayingPosition = Thread.isMainThread
            ? (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue
            : nil
        let stamp = uptimeSeconds()

        queue.async {
            if let observerTrack,
               let liveTrack,
               observerTrack != liveTrack {
                writeDebugLog(
                    "[SpicyRenderer] sample rejected reason=old-observer-track "
                    + "observer=\(observerTrack) live=\(liveTrack)"
                )
                return
            }

            let canonicalTrack = liveTrack ?? observerTrack
            let generation = self.clock.transition(to: canonicalTrack, at: stamp)

            let sameTimeline = observerTrack == nil
                || self.lastObserverTrackIdentifier == nil
                || observerTrack == self.lastObserverTrackIdentifier
            if sameTimeline,
               let sourceTimestamp,
               let previousTimestamp = self.lastObserverSourceTimestamp,
               sourceTimestamp + 0.001 < previousTimestamp {
                writeDebugLog(
                    "[SpicyRenderer] sample rejected reason=out-of-order-observer "
                    + "generation=\(generation) track=\(canonicalTrack ?? "unknown")"
                )
                return
            }

            if let observerTrack,
               observerTrack != self.lastObserverTrackIdentifier {
                self.lastObserverTrackIdentifier = observerTrack
                self.lastObserverSourceTimestamp = nil
                self.playbackUnits = SpicyLyricsPlaybackUnitNormalizer()
            }

            let prior = self.clock.snapshot(at: stamp)
            let duration = self.playbackUnits.durationSeconds(durationRaw)
            let reference = nowPlayingPosition ?? (self.clock.hasAnchor ? prior.positionSeconds : nil)
            let effectivePlaying = playing ?? prior.isPlaying
            let sourceAge = sourceTimestamp.map { callbackTimestamp - $0 }
            let anchorReference = reference.map {
                max(0, $0 - ((effectivePlaying ? max(0, sourceAge ?? 0) : 0) * max(0.1, rate)))
            }
            let timestampedPosition = timestampedPositionRaw.map {
                self.playbackUnits.positionSeconds(
                    $0,
                    durationSeconds: duration,
                    referenceSeconds: anchorReference
                )
            }
            let fallbackPosition = self.playbackUnits.positionSeconds(
                positionRaw,
                durationSeconds: duration,
                referenceSeconds: reference
            )
            let position = SpicyLyricsPlaybackTimestampProjector.positionSeconds(
                anchorPositionSeconds: timestampedPosition,
                fallbackPositionSeconds: fallbackPosition,
                sourceTimestamp: sourceTimestamp,
                callbackTimestamp: callbackTimestamp,
                playbackRate: rate,
                isPlaying: effectivePlaying
            )
            let accepted = self.clock.submit(
                SpicyLyricsPlaybackSample(
                    generation: generation,
                    positionSeconds: position,
                    durationSeconds: duration,
                    playbackRate: rate,
                    isPlaying: effectivePlaying,
                    trackIdentifier: canonicalTrack,
                    source: .observer,
                    // The observer value was projected to callback time above.
                    sampledAtUptimeSeconds: stamp,
                    receivedAtUptimeSeconds: stamp
                )
            )
            self.player = player
            if let sourceTimestamp {
                self.lastObserverSourceTimestamp = max(
                    sourceTimestamp,
                    self.lastObserverSourceTimestamp ?? sourceTimestamp
                )
            }
            if accepted {
                let snapshot = self.clock.snapshot(at: stamp)
                writeDebugLog(
                    "[SpicyRenderer] sample accepted source=observer "
                    + "generation=\(snapshot.generation) sequence=\(snapshot.sequence) "
                    + "position=\(String(format: "%.3f", snapshot.positionSeconds)) "
                    + "playing=\(snapshot.isPlaying)"
                )
            }
        }
    }

    /// Samples the synchronous SPTStatefulPlayerTrackPositionAPI and emits one
    /// immutable renderer snapshot. This method is called from the main thread
    /// by the full-screen host.
    func playbackPayload() -> [String: Any] {
        let direct = Thread.isMainThread ? captureLiveObservation() : nil
        let nowPlaying = Thread.isMainThread ? MPNowPlayingInfoCenter.default().nowPlayingInfo : nil
        let fallbackPosition = (nowPlaying?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue
        let fallbackDuration = (nowPlaying?[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue
        let fallbackRate = (nowPlaying?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue
        let fallbackTrack = Thread.isMainThread
            ? nonEmpty(statefulPlayer?.currentTrack()?.trackIdentifier)
            : nil
        let shuffleAvailable = Thread.isMainThread ? shuffleCommandAvailable() : false
        let repeatAvailable = Thread.isMainThread ? repeatCommandAvailable() : false

        return queue.sync {
            let now = self.uptimeSeconds()

            if let direct {
                self.submit(direct)
            } else {
                let generation = self.clock.transition(to: fallbackTrack, at: now)
                let prior = self.clock.snapshot(at: now)
                let shouldSeedFallback = !self.clock.hasAnchor
                    || prior.freshnessSeconds >= SpicyLyricsPlaybackClock.higherAuthorityFreshnessSeconds
                if shouldSeedFallback, let fallbackPosition {
                    let observation = NativeObservation(
                        positionSeconds: max(0, fallbackPosition),
                        durationSeconds: max(0, fallbackDuration ?? prior.durationSeconds),
                        playbackRate: fallbackRate ?? prior.playbackRate,
                        isPlaying: fallbackRate.map { $0 > 0 } ?? prior.isPlaying,
                        trackIdentifier: fallbackTrack ?? prior.trackIdentifier,
                        shuffleEnabled: nil,
                        repeatMode: nil,
                        sampledAtUptimeSeconds: now,
                        receivedAtUptimeSeconds: now,
                        source: .nowPlayingFallback
                    )
                    self.submit(observation, generation: generation)
                }
            }

            let snapshot = self.clock.snapshot(at: now)
            let visualPosition = snapshot.positionSeconds
                + (snapshot.source == nil ? 0 : Self.perceptualLeadSeconds)
            let boundedVisualPosition = snapshot.durationSeconds > 0
                ? min(snapshot.durationSeconds, visualPosition)
                : visualPosition
            var payload: [String: Any] = [
                "positionMs": Int(max(0, boundedVisualPosition) * 1000),
                "durationMs": Int(max(0, snapshot.durationSeconds) * 1000),
                "isPlaying": snapshot.isPlaying && !snapshot.requiresFreshSample,
                "playbackRate": snapshot.playbackRate,
                "trackId": snapshot.trackIdentifier ?? "",
                "generation": String(snapshot.generation),
                "sequence": String(snapshot.sequence),
                "source": snapshot.source?.rendererValue ?? "unavailable",
                "freshnessMs": Int(min(86_400, snapshot.freshnessSeconds) * 1000),
                "requiresFreshSample": snapshot.requiresFreshSample,
                "shuffleEnabled": self.shuffleEnabled,
                "repeatMode": self.repeatMode,
                "shuffleAvailable": shuffleAvailable,
                "repeatAvailable": repeatAvailable
            ]
            if let pendingSeek = snapshot.pendingSeekTargetSeconds {
                payload["pendingSeekMs"] = Int(pendingSeek * 1000)
            }
            return payload
        }
    }

    func suspendPlaybackClock() {
        let stamp = uptimeSeconds()
        queue.async {
            self.clock.suspend(at: stamp)
            let snapshot = self.clock.snapshot(at: stamp)
            writeDebugLog(
                "[SpicyRenderer] lifecycle hidden generation=\(snapshot.generation) "
                + "sequence=\(snapshot.sequence) position="
                + "\(String(format: "%.3f", snapshot.positionSeconds))"
            )
        }
    }

    /// Foreground payloads remain frozen until captureLiveObservation submits a
    /// fresh stateful-player position in playbackPayload().
    func foregroundPayload() -> [String: Any] {
        let stamp = uptimeSeconds()
        queue.sync {
            self.clock.resumeAwaitingFreshSample(at: stamp)
        }
        return playbackPayload()
    }

    func currentTrackID() -> String? {
        if let identifier = nonEmpty(statefulPlayer?.currentTrack()?.trackIdentifier) {
            return identifier
        }
        return queue.sync { clock.trackIdentifier }
    }

    /// UI metadata is deliberately read on the main thread. The artwork is
    /// converted to a bounded data URL so the local canvas remains same-origin.
    func trackPayload() -> [String: Any] {
        precondition(Thread.isMainThread)

        let nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let track = statefulPlayer?.currentTrack()
        let metadata = track?.metadata() ?? [:]
        let trackID = track?.trackIdentifier ?? currentTrackID() ?? ""
        let title = nonEmpty(track?.trackTitle())
            ?? nonEmpty(nowPlaying[MPMediaItemPropertyTitle] as? String)
            ?? capturedTrackTitle
            ?? "Unknown track"
        let artist = nonEmpty(track?.artistName())
            ?? nonEmpty(nowPlaying[MPMediaItemPropertyArtist] as? String)
            ?? capturedArtistName
            ?? "Unknown artist"
        let album = nonEmpty(nowPlaying[MPMediaItemPropertyAlbumTitle] as? String)
            ?? nonEmpty(metadata["album_title"])
            ?? ""
        let duration = (nowPlaying[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue
            ?? Double(playbackPayload()["durationMs"] as? Int ?? 0) / 1000

        let artworkDataURL = artworkDataURL(
            from: nowPlaying[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        )
        let artworkURL = artworkDataURL
            ?? normalizedArtworkURL(from: metadata)
            ?? ""

        return [
            "id": trackID,
            "uri": trackID.isEmpty ? "" : "spotify:track:\(trackID)",
            "title": title,
            "artist": artist,
            "album": album,
            "durationMs": Int(max(0, duration) * 1000),
            "artwork": artworkURL,
            "dominantColor": track?.extractedColorHex() ?? ""
        ]
    }

    @discardableResult
    func perform(command: String, value: Double? = nil) -> Bool {
        let capturedPlayer = queue.sync(execute: { self.player })
        let statefulCandidate: AnyObject? = statefulPlayer.map { $0 as AnyObject }
        let corePlayer = safeRead(statefulCandidate, key: "player") as AnyObject?
        let candidates = uniqueCandidates([statefulCandidate, corePlayer, capturedPlayer])
        guard !candidates.isEmpty else {
            writeDebugLog("[SpicyRenderer] command \(command) rejected: no player")
            return false
        }

        if command == "seek", let seconds = value {
            return seek(players: candidates, seconds: max(0, seconds))
        }

        switch command {
        case "togglePlay":
            let shouldPlay: Bool
            if let paused = safeBool(statefulCandidate, key: "isPaused") {
                shouldPlay = paused
            } else {
                shouldPlay = !queue.sync {
                    self.clock.snapshot(at: self.uptimeSeconds()).isPlaying
                }
            }
            return setPlaying(shouldPlay, candidates: candidates)
        case "play":
            return setPlaying(true, candidates: candidates)
        case "pause":
            return setPlaying(false, candidates: candidates)
        case "toggleShuffle":
            return setShuffle(candidates: candidates)
        case "cycleRepeat":
            return cycleRepeatMode(candidates: candidates)
        default:
            return false
        }
    }

    /// Tries the transport APIs actually exposed by Spotify 9.1.x and reports
    /// success only after playback state changes.
    func performSkip(command: String, completion: @escaping (Bool) -> Void) {
        guard command == "next" || command == "previous" else {
            completion(false)
            return
        }

        let capturedPlayer = queue.sync(execute: { self.player })
        let statefulCandidate: AnyObject? = statefulPlayer.map { $0 as AnyObject }
        let corePlayer = safeRead(statefulCandidate, key: "player") as AnyObject?
        let candidates = uniqueCandidates([capturedPlayer, corePlayer, statefulCandidate])
        let attempts = transportAttempts(command: command, candidates: candidates)
        guard !attempts.isEmpty else {
            writeDebugLog("[SpicyRenderer] command \(command) unavailable: no compatible transport selector")
            completion(false)
            return
        }

        let baseline = transportMarker()
        runTransportAttempt(
            attempts,
            index: 0,
            command: command,
            baseline: baseline,
            completion: completion
        )
    }

    private enum TransportInvocation {
        case noArgument
        case nilObject
    }

    private struct TransportAttempt {
        let target: AnyObject
        let selector: Selector
        let invocation: TransportInvocation
    }

    private struct TransportMarker {
        let trackIdentifier: String?
        let positionSeconds: Double
    }

    private func transportAttempts(command: String, candidates: [AnyObject]) -> [TransportAttempt] {
        let oneArgumentNames = command == "next"
            ? ["skipToNextTrackWithOptions:", "skipToNextTrackWithCompletionHandler:", "skipToNextTrack:"]
            : ["skipToPreviousTrackWithOptions:", "skipToPreviousTrackWithCompletionHandler:", "skipToPreviousTrack:"]
        let zeroArgumentNames = command == "next"
            ? ["skipToNextTrack", "skipToNext", "nextTrack"]
            : ["skipToPreviousTrack", "skipToPrevious", "previousTrack"]

        var attempts = [TransportAttempt]()
        for target in candidates {
            for name in oneArgumentNames {
                let selector = NSSelectorFromString(name)
                guard target.responds(to: selector),
                      let method = class_getInstanceMethod(object_getClass(target), selector),
                      method_getNumberOfArguments(method) == 3,
                      let rawType = method_copyArgumentType(method, 2) else { continue }
                defer { free(rawType) }
                let argumentType = String(cString: rawType)
                guard argumentType.hasPrefix("@"), !argumentType.hasPrefix("@?") else { continue }
                attempts.append(
                    TransportAttempt(target: target, selector: selector, invocation: .nilObject)
                )
            }
            for name in zeroArgumentNames {
                let selector = NSSelectorFromString(name)
                guard target.responds(to: selector),
                      let method = class_getInstanceMethod(object_getClass(target), selector),
                      method_getNumberOfArguments(method) == 2 else { continue }
                attempts.append(
                    TransportAttempt(target: target, selector: selector, invocation: .noArgument)
                )
            }
        }
        return Array(attempts.prefix(8))
    }

    private func runTransportAttempt(
        _ attempts: [TransportAttempt],
        index: Int,
        command: String,
        baseline: TransportMarker,
        completion: @escaping (Bool) -> Void
    ) {
        guard index < attempts.count else {
            writeDebugLog("[SpicyRenderer] command \(command) exhausted \(attempts.count) transport attempts")
            completion(false)
            return
        }

        let attempt = attempts[index]
        let typeName = String(describing: type(of: attempt.target))
        let selectorName = NSStringFromSelector(attempt.selector)
        writeDebugLog("[SpicyRenderer] command \(command) trying -[\(typeName) \(selectorName)]")
        executeOnMain {
            switch attempt.invocation {
            case .noArgument:
                EeveeInvokeVoidNoArg(attempt.target, attempt.selector)
            case .nilObject:
                EeveeInvokeObjectArg(attempt.target, attempt.selector, nil)
            }
        }

        verifyTransportEffect(baseline: baseline, remainingPolls: 8) { [weak self] changed in
            guard let self else { return }
            if changed {
                writeDebugLog("[SpicyRenderer] command \(command) accepted by -[\(typeName) \(selectorName)]")
                completion(true)
            } else {
                self.runTransportAttempt(
                    attempts,
                    index: index + 1,
                    command: command,
                    baseline: baseline,
                    completion: completion
                )
            }
        }
    }

    private func verifyTransportEffect(
        baseline: TransportMarker,
        remainingPolls: Int,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            let marker = self.transportMarker()
            let trackChanged = marker.trackIdentifier?.isEmpty == false
                && marker.trackIdentifier != baseline.trackIdentifier
            let restarted = baseline.positionSeconds > 1.5
                && marker.positionSeconds + 1.25 < baseline.positionSeconds
            if trackChanged || restarted {
                completion(true)
            } else if remainingPolls > 1 {
                self.verifyTransportEffect(
                    baseline: baseline,
                    remainingPolls: remainingPolls - 1,
                    completion: completion
                )
            } else {
                completion(false)
            }
        }
    }

    private func transportMarker() -> TransportMarker {
        let liveIdentifier = nonEmpty(statefulPlayer?.currentTrack()?.trackIdentifier)
        let livePosition = livePositionSeconds()
        return queue.sync {
            let snapshot = clock.snapshot(at: uptimeSeconds())
            return TransportMarker(
                trackIdentifier: liveIdentifier ?? snapshot.trackIdentifier,
                positionSeconds: livePosition ?? snapshot.positionSeconds
            )
        }
    }

    private func setPlaying(_ shouldPlay: Bool, candidates: [AnyObject]) -> Bool {
        let pausedSelector = NSSelectorFromString("setIsPaused:")
        if let target = candidates.first(where: { $0.responds(to: pausedSelector) }) {
            writeDebugLog("[SpicyRenderer] command \(shouldPlay ? "play" : "pause") requested")
            executeOnMain { EeveeInvokeBoolArg(target, pausedSelector, !shouldPlay) }
            return true
        }

        let optionSelector = NSSelectorFromString(shouldPlay ? "resume:" : "pause:")
        if let target = candidates.first(where: { $0.responds(to: optionSelector) }) {
            writeDebugLog("[SpicyRenderer] command \(shouldPlay ? "play" : "pause") requested")
            executeOnMain { EeveeInvokeObjectArg(target, optionSelector, nil) }
            return true
        }

        let zeroArgumentNames = shouldPlay
            ? ["play", "resume", "togglePlayPause"]
            : ["pause", "togglePlayPause"]
        return invokeVoid(
            names: zeroArgumentNames,
            candidates: candidates,
            command: shouldPlay ? "play" : "pause"
        )
    }

    private func setShuffle(candidates: [AnyObject]) -> Bool {
        let observed = observedShuffleState(candidates: candidates)
            ?? queue.sync { self.shuffleEnabled }
        let desired = !observed
        let names = ["setIsShufflingContext:", "setShufflingContext:", "setShuffle:"]
        guard invokeBool(names: names, value: desired, candidates: candidates) else {
            writeDebugLog("[SpicyRenderer] command shuffle unavailable")
            return false
        }
        writeDebugLog("[SpicyRenderer] command shuffle requested=\(desired) observed=\(observed)")
        return true
    }

    private func cycleRepeatMode(candidates: [AnyObject]) -> Bool {
        let observed = observedRepeatMode(candidates: candidates)
            ?? queue.sync { self.repeatMode }
        let desired: String
        switch observed {
        case "context": desired = "track"
        case "track": desired = "off"
        default: desired = "context"
        }

        let changedTrack: Bool
        let changedContext: Bool
        switch desired {
        case "track":
            changedContext = invokeBool(
                names: ["setRepeatingContext:"],
                value: true,
                candidates: candidates
            )
            changedTrack = invokeBool(
                names: ["setRepeatingTrack:"],
                value: true,
                candidates: candidates
            )
        case "context":
            changedTrack = invokeBool(
                names: ["setRepeatingTrack:"],
                value: false,
                candidates: candidates
            )
            changedContext = invokeBool(
                names: ["setRepeatingContext:"],
                value: true,
                candidates: candidates
            )
        default:
            changedTrack = invokeBool(
                names: ["setRepeatingTrack:"],
                value: false,
                candidates: candidates
            )
            changedContext = invokeBool(
                names: ["setRepeatingContext:"],
                value: false,
                candidates: candidates
            )
        }

        let accepted = changedTrack || changedContext
        writeDebugLog(
            "[SpicyRenderer] command repeat requested=\(desired) observed=\(observed) accepted=\(accepted)"
        )
        return accepted
    }

    private func invokeVoid(
        names: [String],
        candidates: [AnyObject],
        command: String
    ) -> Bool {
        for target in candidates {
            guard let selector = names.lazy
                .map(NSSelectorFromString)
                .first(where: { target.responds(to: $0) }) else { continue }
            executeOnMain { EeveeInvokeVoidNoArg(target, selector) }
            writeDebugLog("[SpicyRenderer] command \(command) requested")
            return true
        }

        let types = candidates.map { String(describing: type(of: $0)) }.joined(separator: ", ")
        writeDebugLog("[SpicyRenderer] command \(command) unavailable on [\(types)]")
        return false
    }

    private func invokeBool(
        names: [String],
        value: Bool,
        candidates: [AnyObject]
    ) -> Bool {
        for target in candidates {
            for name in names {
                let selector = NSSelectorFromString(name)
                guard target.responds(to: selector),
                      let method = class_getInstanceMethod(object_getClass(target), selector),
                      method_getNumberOfArguments(method) == 3,
                      let rawType = method_copyArgumentType(method, 2) else { continue }
                defer { free(rawType) }
                let argumentType = String(cString: rawType)
                guard argumentType == "B" || argumentType == "c" else { continue }
                executeOnMain { EeveeInvokeBoolArg(target, selector, value) }
                return true
            }
        }
        return false
    }

    private func seek(players: [AnyObject], seconds: Double) -> Bool {
        let names = ["seekTo:", "scrubTo:", "seekToPosition:"]
        for player in players {
            for name in names {
                let selector = NSSelectorFromString(name)
                guard player.responds(to: selector),
                      let method = class_getInstanceMethod(object_getClass(player), selector) else { continue }

                let argumentType: String = {
                    guard let raw = method_copyArgumentType(method, 2) else { return "?" }
                    defer { free(raw) }
                    return String(cString: raw)
                }()
                guard argumentType == "d" else { continue }

                let stamp = uptimeSeconds()
                let recorded = queue.sync {
                    self.clock.requestSeek(
                        to: seconds,
                        generation: self.clock.generation,
                        at: stamp
                    )
                }
                guard recorded else {
                    writeDebugLog("[SpicyRenderer] seek rejected: no current player sample")
                    return false
                }
                writeDebugLog(
                    "[SpicyRenderer] command seek requested position="
                    + "\(String(format: "%.3f", seconds))"
                )
                executeOnMain { EeveeSBInvokeSeekDouble(player, selector, seconds) }
                return true
            }
        }

        let types = players.map { String(describing: type(of: $0)) }.joined(separator: ", ")
        writeDebugLog("[SpicyRenderer] seek unavailable on [\(types)]")
        return false
    }

    private func captureLiveObservation() -> NativeObservation? {
        precondition(Thread.isMainThread)
        let statefulCandidate: AnyObject? = statefulPlayer.map { $0 as AnyObject }
        let corePlayer = safeRead(statefulCandidate, key: "player") as AnyObject?
        let candidates = uniqueCandidates([statefulCandidate, corePlayer])
        guard !candidates.isEmpty else { return nil }

        let requestStarted = uptimeSeconds()
        guard let position = candidates.lazy.compactMap({
            safeDoubleGetter($0, key: "position")
        }).first else { return nil }
        let duration = candidates.lazy.compactMap {
            safeDoubleGetter($0, key: "duration")
        }.first ?? 0
        let rate = candidates.lazy.compactMap {
            safeDoubleGetter($0, key: "playbackSpeed")
        }.first ?? 1
        let playing = observedPlayingState(candidates: candidates)
            ?? ((MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? 0) > 0
        let trackIdentifier = nonEmpty(statefulPlayer?.currentTrack()?.trackIdentifier)
        let shuffle = observedShuffleState(candidates: candidates)
        let repeatMode = observedRepeatMode(candidates: candidates)
        let received = uptimeSeconds()
        let midpoint = requestStarted + (received - requestStarted) / 2

        return NativeObservation(
            positionSeconds: max(0, position),
            durationSeconds: max(0, duration),
            playbackRate: rate > 0 ? rate : 1,
            isPlaying: playing,
            trackIdentifier: trackIdentifier,
            shuffleEnabled: shuffle,
            repeatMode: repeatMode,
            sampledAtUptimeSeconds: midpoint,
            receivedAtUptimeSeconds: received,
            source: .statefulPlayer
        )
    }

    private func submit(_ observation: NativeObservation, generation explicitGeneration: UInt64? = nil) {
        let generation = explicitGeneration
            ?? clock.transition(
                to: observation.trackIdentifier,
                at: observation.receivedAtUptimeSeconds
            )
        let accepted = clock.submit(
            SpicyLyricsPlaybackSample(
                generation: generation,
                positionSeconds: observation.positionSeconds,
                durationSeconds: observation.durationSeconds,
                playbackRate: observation.playbackRate,
                isPlaying: observation.isPlaying,
                trackIdentifier: observation.trackIdentifier,
                source: observation.source,
                sampledAtUptimeSeconds: observation.sampledAtUptimeSeconds,
                receivedAtUptimeSeconds: observation.receivedAtUptimeSeconds
            )
        )
        if let shuffle = observation.shuffleEnabled { shuffleEnabled = shuffle }
        if let repeatMode = observation.repeatMode { self.repeatMode = repeatMode }

        let snapshot = clock.snapshot(at: observation.receivedAtUptimeSeconds)
        let shouldLogAccepted = observation.source != .statefulPlayer
            || observation.receivedAtUptimeSeconds - lastDiagnosticStamp >= 2
            || observation.isPlaying != lastDiagnosticPlaying
            || observation.trackIdentifier != lastDiagnosticTrackIdentifier
        if accepted {
            if shouldLogAccepted {
                writeDebugLog(
                    "[SpicyRenderer] sample accepted source=\(observation.source.rendererValue) "
                    + "generation=\(snapshot.generation) sequence=\(snapshot.sequence) "
                    + "rtt=\(String(format: "%.3f", observation.receivedAtUptimeSeconds - observation.sampledAtUptimeSeconds)) "
                    + "position=\(String(format: "%.3f", snapshot.positionSeconds)) "
                    + "playing=\(snapshot.isPlaying)"
                )
                lastDiagnosticStamp = observation.receivedAtUptimeSeconds
                lastDiagnosticPlaying = observation.isPlaying
                lastDiagnosticTrackIdentifier = observation.trackIdentifier
            }
        } else {
            writeDebugLog(
                "[SpicyRenderer] sample rejected source=\(observation.source.rendererValue) "
                + "generation=\(generation) currentGeneration=\(snapshot.generation)"
            )
        }
    }

    private func livePositionSeconds() -> Double? {
        guard Thread.isMainThread else { return nil }
        let statefulCandidate: AnyObject? = statefulPlayer.map { $0 as AnyObject }
        let corePlayer = safeRead(statefulCandidate, key: "player") as AnyObject?
        return uniqueCandidates([statefulCandidate, corePlayer]).lazy.compactMap {
            safeDoubleGetter($0, key: "position")
        }.first
    }

    private func shuffleCommandAvailable() -> Bool {
        guard Thread.isMainThread else { return false }
        let statefulCandidate: AnyObject? = statefulPlayer.map { $0 as AnyObject }
        let corePlayer = safeRead(statefulCandidate, key: "player") as AnyObject?
        let selectors = ["setIsShufflingContext:", "setShufflingContext:", "setShuffle:"]
            .map(NSSelectorFromString)
        return uniqueCandidates([statefulCandidate, corePlayer]).contains { target in
            selectors.contains { target.responds(to: $0) }
        }
    }

    private func repeatCommandAvailable() -> Bool {
        guard Thread.isMainThread else { return false }
        let statefulCandidate: AnyObject? = statefulPlayer.map { $0 as AnyObject }
        let corePlayer = safeRead(statefulCandidate, key: "player") as AnyObject?
        let selectors = ["setRepeatingContext:", "setRepeatingTrack:"].map(NSSelectorFromString)
        return uniqueCandidates([statefulCandidate, corePlayer]).contains { target in
            selectors.contains { target.responds(to: $0) }
        }
    }

    private func observedShuffleState(candidates: [AnyObject]) -> Bool? {
        for candidate in candidates {
            if let value = safeBool(candidate, key: "isShufflingContext") { return value }
            if let value = safeBool(candidate, key: "isShuffleEnabled") { return value }
        }
        return nil
    }

    private func observedRepeatMode(candidates: [AnyObject]) -> String? {
        for candidate in candidates {
            if safeBool(candidate, key: "isRepeatingTrack") == true { return "track" }
        }
        for candidate in candidates {
            if safeBool(candidate, key: "isRepeatingContext") == true { return "context" }
        }
        let exposesRepeat = candidates.contains {
            $0.responds(to: NSSelectorFromString("isRepeatingTrack"))
                || $0.responds(to: NSSelectorFromString("isRepeatingContext"))
        }
        return exposesRepeat ? "off" : nil
    }

    private func uniqueCandidates(_ values: [AnyObject?]) -> [AnyObject] {
        var identifiers = Set<ObjectIdentifier>()
        return values.compactMap { value in
            guard let value else { return nil }
            let identifier = ObjectIdentifier(value)
            guard identifiers.insert(identifier).inserted else { return nil }
            return value
        }
    }

    private func executeOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    private func artworkDataURL(from artwork: MPMediaItemArtwork?) -> String? {
        guard let image = artwork?.image(at: CGSize(width: 640, height: 640)) else { return nil }
        let size = CGSize(width: 640, height: 640)
        let renderer = UIGraphicsImageRenderer(size: size)
        let square = renderer.image { _ in
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(
                x: (size.width - drawSize.width) / 2,
                y: (size.height - drawSize.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        guard let data = square.jpegData(compressionQuality: 0.86) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private func normalizedArtworkURL(from metadata: [String: String]) -> String? {
        let keys = [
            "image_xlarge_url",
            "image_large_url",
            "image_url",
            "album_image_url",
            "cover_url",
            "image_uri"
        ]
        guard let raw = keys.lazy.compactMap({ self.nonEmpty(metadata[$0]) }).first else {
            return nil
        }
        if raw.hasPrefix("spotify:image:") {
            return "https://i.scdn.co/image/\(raw.replacingOccurrences(of: "spotify:image:", with: ""))"
        }
        return raw
    }

    private func extractURI(from track: AnyObject?) -> String? {
        guard let track else { return nil }
        if let string = safeRead(track, key: "URI") as? String { return string }
        if let url = safeRead(track, key: "URI") as? URL { return url.absoluteString }
        if let value = safeRead(track, key: "uri") as? String { return value }
        return nil
    }

    private func spotifyTrackID(from uri: String) -> String? {
        if uri.hasPrefix("spotify:track:") {
            return String(uri.dropFirst("spotify:track:".count))
        }
        if let range = uri.range(of: "/track/") {
            return String(uri[range.upperBound...]).split(separator: "?").first.map(String.init)
        }
        return nil
    }

    private func safeRead(_ object: AnyObject?, key: String) -> Any? {
        guard let object, object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    private func safeDoubleGetter(_ object: AnyObject, key: String) -> Double? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(object_getClass(object), selector),
              method_getNumberOfArguments(method) == 2,
              let rawType = method_copyReturnType(method) else { return nil }
        defer { free(rawType) }
        let returnType = String(cString: rawType)
        guard returnType == "d" || returnType == "f" || returnType.hasPrefix("@") else {
            return nil
        }
        guard let number = object.value(forKey: key) as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private func safeBool(_ object: AnyObject?, key: String) -> Bool? {
        guard let value = safeRead(object, key: key) else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool
    }

    private func observedPlayingState(candidates: [AnyObject]) -> Bool? {
        for candidate in candidates {
            if let paused = safeBool(candidate, key: "isPaused") { return !paused }
            if let playing = safeBool(candidate, key: "isPlaying") { return playing }
        }
        return nil
    }

    private func dateTimestamp(_ value: Any?) -> TimeInterval? {
        if let date = value as? Date { return date.timeIntervalSince1970 }
        if let date = value as? NSDate { return date.timeIntervalSince1970 }
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw > 0 else { return nil }
        return raw > 10_000_000_000 ? raw / 1000 : raw
    }

    private func uptimeSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
