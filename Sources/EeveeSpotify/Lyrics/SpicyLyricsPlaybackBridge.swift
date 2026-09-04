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
        let duration = normalizeSeconds(durationRaw, durationHint: durationRaw)
        let position = normalizeSeconds(positionRaw, durationHint: durationRaw)
        let stamp = uptimeSeconds()

        queue.async {
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

    func playbackPayload() -> [String: Any] {
        let nowPlaying = Thread.isMainThread ? MPNowPlayingInfoCenter.default().nowPlayingInfo : nil
        let fallbackPosition = (nowPlaying?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue
        let fallbackDuration = (nowPlaying?[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue
        let fallbackRate = (nowPlaying?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue

        return queue.sync {
            let now = uptimeSeconds()
            let observerIsFresh = lastObserverStamp != 0 && now - lastObserverStamp < 2

            if (!observerIsFresh || !clock.hasAnchor), let fallbackPosition {
                clock.observe(
                    positionSeconds: max(0, fallbackPosition),
                    durationSeconds: max(0, fallbackDuration ?? 0),
                    playbackRate: fallbackRate ?? 1,
                    isPlaying: fallbackRate.map { $0 > 0 },
                    trackIdentifier: clock.trackIdentifier,
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
            if let paused = safeBool(statefulCandidate, key: "isPaused") {
                shouldPlay = paused
            } else {
                shouldPlay = !queue.sync { self.clock.snapshot(at: self.uptimeSeconds()).isPlaying }
            }
            return setPlaying(shouldPlay, candidates: candidates)
        case "play":
            return setPlaying(true, candidates: candidates)
        case "pause":
            return setPlaying(false, candidates: candidates)
        case "next":
            return invokeVoid(
                names: ["skipToNextTrack", "skipToNext"],
                candidates: candidates,
                command: command
            )
        case "previous":
            return invokeVoid(
                names: ["skipToPreviousTrack", "skipToPrevious"],
                candidates: candidates,
                command: command
            )
        default:
            return false
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
            self.clock.reconcilePlaybackState(
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

    private func normalizeSeconds(_ raw: Double, durationHint: Double) -> Double {
        (raw > 10_000 || durationHint > 10_000) ? raw / 1000 : raw
    }

    private func uptimeSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
