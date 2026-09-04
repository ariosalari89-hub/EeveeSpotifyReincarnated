import Foundation
import MediaPlayer
import ObjectiveC.runtime
import UIKit
import EeveeSpotifyC

/// Native half of the local renderer's playback bridge. Spotify's observer is
/// the source of truth; JavaScript only interpolates between these snapshots.
final class SpicyLyricsPlaybackBridge {
    static let shared = SpicyLyricsPlaybackBridge()

    private let queue = DispatchQueue(label: "com.eevee.spicylyrics.playback")
    private weak var player: AnyObject?
    private var clock = SpicyLyricsPlaybackClock()
    private var playbackUnits = SpicyLyricsPlaybackUnitNormalizer()
    private var lastObserverStamp = 0.0
    private var lastObserverReportedPlaying: Bool?
    private var sequence: UInt64 = 0

    private init() {}

    func processStateChange(player: AnyObject, state: AnyObject) {
        let positionRaw = (safeRead(state, key: "position") as? NSNumber)?.doubleValue ?? 0
        let durationRaw = (safeRead(state, key: "duration") as? NSNumber)?.doubleValue ?? 0
        let rate = (safeRead(state, key: "playbackSpeed") as? NSNumber)?.doubleValue ?? 1
        let playing = safeBool(state, key: "isPlaying")
        let track = safeRead(state, key: "track") as AnyObject?
        let uri = extractURI(from: track)
        let trackIdentifier = uri.flatMap { spotifyTrackID(from: $0) }
        let stamp = uptimeSeconds()
        let systemPosition = Thread.isMainThread
            ? (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue
            : nil

        queue.async {
            let duration = self.playbackUnits.durationSeconds(durationRaw)
            let referencePosition: Double?
            if let systemPosition {
                referencePosition = systemPosition
            } else if self.clock.hasAnchor {
                referencePosition = self.clock.snapshot(at: stamp).positionSeconds
            } else {
                referencePosition = nil
            }
            let position = self.playbackUnits.positionSeconds(
                positionRaw,
                durationSeconds: duration,
                referenceSeconds: referencePosition
            )
            self.player = player
            self.clock.observe(
                positionSeconds: position,
                durationSeconds: duration,
                playbackRate: rate,
                isPlaying: playing,
                trackIdentifier: trackIdentifier,
                at: stamp
            )
            self.lastObserverStamp = stamp
            self.lastObserverReportedPlaying = playing
            self.sequence &+= 1
        }
    }

    func playbackPayload(forceNowPlayingReanchor: Bool = false) -> [String: Any] {
        let nowPlaying = Thread.isMainThread ? MPNowPlayingInfoCenter.default().nowPlayingInfo : nil
        let fallbackPosition = (nowPlaying?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue
        let fallbackDuration = (nowPlaying?[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue
        let fallbackRate = (nowPlaying?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue
        let liveTrackIdentifier = Thread.isMainThread ? statefulPlayer?.currentTrack()?.trackIdentifier : nil

        return queue.sync {
            let now = uptimeSeconds()
            let observerIsFresh = lastObserverStamp != 0 && now - lastObserverStamp < 2

            if forceNowPlayingReanchor, !observerIsFresh, let fallbackPosition {
                let prior = clock.snapshot(at: now)
                clock.reanchor(
                    positionSeconds: max(0, fallbackPosition),
                    durationSeconds: max(0, fallbackDuration ?? prior.durationSeconds),
                    playbackRate: fallbackRate ?? prior.playbackRate,
                    isPlaying: fallbackRate.map { $0 > 0 } ?? prior.isPlaying,
                    trackIdentifier: liveTrackIdentifier ?? prior.trackIdentifier,
                    at: now
                )
                lastObserverStamp = 0
                lastObserverReportedPlaying = fallbackRate.map { $0 > 0 }
                sequence &+= 1
            } else if (!observerIsFresh || !clock.hasAnchor), let fallbackPosition {
                clock.observe(
                    positionSeconds: max(0, fallbackPosition),
                    durationSeconds: max(0, fallbackDuration ?? 0),
                    playbackRate: fallbackRate ?? 1,
                    isPlaying: fallbackRate.map { $0 > 0 },
                    trackIdentifier: liveTrackIdentifier ?? clock.trackIdentifier,
                    at: now
                )
                sequence &+= 1
            } else if observerIsFresh,
                      lastObserverReportedPlaying == nil,
                      let fallbackRate {
                clock.reconcilePlaybackState(
                    isPlaying: fallbackRate > 0,
                    playbackRate: fallbackRate,
                    at: now
                )
            }

            let snapshot = clock.snapshot(at: now)
            return [
                "positionMs": Int(snapshot.positionSeconds * 1000),
                "durationMs": Int(snapshot.durationSeconds * 1000),
                "isPlaying": snapshot.isPlaying,
                "playbackRate": snapshot.playbackRate,
                "trackId": snapshot.trackIdentifier ?? "",
                "sequence": String(sequence)
            ]
        }
    }

    /// Forces the next payload to use iOS's live Now Playing position. The app
    /// and WKWebView can suspend independently, so their old monotonic anchors
    /// cannot safely be extrapolated after returning to the foreground.
    func foregroundPayload() -> [String: Any] {
        playbackPayload(forceNowPlayingReanchor: true)
    }

    func currentTrackID() -> String? {
        if let track = statefulPlayer?.currentTrack() {
            let identifier = track.trackIdentifier
            if !identifier.isEmpty { return identifier }
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

        let artworkDataURL = artworkDataURL(from: nowPlaying[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
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
            let bridgePlaying: Bool? = queue.sync {
                guard self.clock.hasAnchor else { return nil }
                return self.clock.snapshot(at: self.uptimeSeconds()).isPlaying
            }
            if let bridgePlaying {
                shouldPlay = !bridgePlaying
            } else if let paused = safeBool(statefulCandidate, key: "isPaused") {
                shouldPlay = paused
            } else {
                shouldPlay = true
            }
            return setPlaying(shouldPlay, candidates: candidates)
        case "play":
            return setPlaying(true, candidates: candidates)
        case "pause":
            return setPlaying(false, candidates: candidates)
        case "next":
            return false
        case "previous":
            return false
        default:
            return false
        }
    }

    /// Tries the transport APIs actually exposed by Spotify 9.1.x and reports
    /// success only after playback state changes. Several objects respond to a
    /// zero-argument skip selector while silently doing nothing; treating
    /// `responds(to:)` as success is what broke the renderer's skip buttons.
    func performSkip(command: String, completion: @escaping (Bool) -> Void) {
        guard command == "next" || command == "previous" else {
            completion(false)
            return
        }

        let capturedPlayer = queue.sync(execute: { self.player })
        let statefulCandidate: AnyObject? = statefulPlayer.map { $0 as AnyObject }
        let corePlayer = safeRead(statefulCandidate, key: "player") as AnyObject?
        // The observer's concrete player owns working transport methods more
        // often than the feature-scoped StatefulPlayer facade.
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
                // A nil options object is safe; a nonnull completion block is
                // not. Block-taking variants remain excluded unless their ABI
                // can be invoked with a correctly typed callback.
                guard argumentType.hasPrefix("@"), !argumentType.hasPrefix("@?") else { continue }
                attempts.append(TransportAttempt(target: target, selector: selector, invocation: .nilObject))
            }
            for name in zeroArgumentNames {
                let selector = NSSelectorFromString(name)
                guard target.responds(to: selector),
                      let method = class_getInstanceMethod(object_getClass(target), selector),
                      method_getNumberOfArguments(method) == 2 else { continue }
                attempts.append(TransportAttempt(target: target, selector: selector, invocation: .noArgument))
            }
        }
        // Bound the retry window so a genuinely restricted queue does not leave
        // the UI pending indefinitely.
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

        verifyTransportEffect(
            baseline: baseline,
            remainingPolls: 8
        ) { [weak self] changed in
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
        let liveIdentifier = Thread.isMainThread ? statefulPlayer?.currentTrack()?.trackIdentifier : nil
        return queue.sync {
            let snapshot = clock.snapshot(at: uptimeSeconds())
            return TransportMarker(
                trackIdentifier: liveIdentifier ?? snapshot.trackIdentifier,
                positionSeconds: snapshot.positionSeconds
            )
        }
    }

    private func setPlaying(_ shouldPlay: Bool, candidates: [AnyObject]) -> Bool {
        // Spotify 9.1.76's StatefulPlayerImplementation implements
        // SPTStatefulPlayerPlaybackControlsAPI directly. Its public playback
        // setter is setIsPaused:, not the play/pause selectors used by older
        // bridge revisions.
        let pausedSelector = NSSelectorFromString("setIsPaused:")
        if let target = candidates.first(where: { $0.responds(to: pausedSelector) }) {
            recordRequestedPlayback(isPlaying: shouldPlay)
            executeOnMain { EeveeInvokeBoolArg(target, pausedSelector, !shouldPlay) }
            return true
        }

        // Older SPTPlayer implementations expose pause:/resume: and accept a
        // nil options object. Keep this as a narrow compatibility fallback.
        let optionSelector = NSSelectorFromString(shouldPlay ? "resume:" : "pause:")
        if let target = candidates.first(where: { $0.responds(to: optionSelector) }) {
            recordRequestedPlayback(isPlaying: shouldPlay)
            executeOnMain { EeveeInvokeObjectArg(target, optionSelector, nil) }
            return true
        }

        let zeroArgumentNames = shouldPlay
            ? ["play", "resume", "togglePlayPause"]
            : ["pause", "togglePlayPause"]
        return invokeVoid(
            names: zeroArgumentNames,
            candidates: candidates,
            command: shouldPlay ? "play" : "pause",
            requestedPlaying: shouldPlay
        )
    }

    private func invokeVoid(
        names: [String],
        candidates: [AnyObject],
        command: String,
        requestedPlaying: Bool? = nil
    ) -> Bool {
        for target in candidates {
            guard let selector = names.lazy
                .map(NSSelectorFromString)
                .first(where: { target.responds(to: $0) }) else { continue }
            if let requestedPlaying { recordRequestedPlayback(isPlaying: requestedPlaying) }
            executeOnMain { EeveeInvokeVoidNoArg(target, selector) }
            return true
        }

        let types = candidates.map { String(describing: type(of: $0)) }.joined(separator: ", ")
        writeDebugLog("[SpicyRenderer] command \(command) unavailable on [\(types)]")
        return false
    }

    private func seek(players: [AnyObject], seconds: Double) -> Bool {
        // Both SPTStatefulPlayerTrackPositionAPI and SPTPlayer use a Double
        // argument for seekTo:. Validate the runtime encoding before invoking
        // it so an integer/millisecond API can never be called with the wrong
        // ABI.
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
                queue.async {
                    self.clock.requestedSeek(to: seconds, at: stamp)
                    self.sequence &+= 1
                }
                executeOnMain { EeveeSBInvokeSeekDouble(player, selector, seconds) }
                return true
            }
        }

        let types = players.map { String(describing: type(of: $0)) }.joined(separator: ", ")
        writeDebugLog("[SpicyRenderer] seek unavailable on [\(types)]")
        return false
    }

    private func recordRequestedPlayback(isPlaying: Bool) {
        let stamp = uptimeSeconds()
        queue.async {
            let rate = self.clock.snapshot(at: stamp).playbackRate
            self.clock.requestedPlaybackState(
                isPlaying: isPlaying,
                playbackRate: rate,
                at: stamp
            )
            self.lastObserverReportedPlaying = isPlaying
            self.sequence &+= 1
        }
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
            let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        guard let data = square.jpegData(compressionQuality: 0.86) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private func normalizedArtworkURL(from metadata: [String: String]) -> String? {
        let keys = ["image_xlarge_url", "image_large_url", "image_url", "album_image_url", "cover_url", "image_uri"]
        guard let raw = keys.lazy.compactMap({ self.nonEmpty(metadata[$0]) }).first else { return nil }
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
        if uri.hasPrefix("spotify:track:") { return String(uri.dropFirst("spotify:track:".count)) }
        if let range = uri.range(of: "/track/") {
            return String(uri[range.upperBound...]).split(separator: "?").first.map(String.init)
        }
        return nil
    }

    private func safeRead(_ object: AnyObject?, key: String) -> Any? {
        guard let object, object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    private func safeBool(_ object: AnyObject?, key: String) -> Bool? {
        guard let value = safeRead(object, key: key) else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool
    }

    private func uptimeSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
