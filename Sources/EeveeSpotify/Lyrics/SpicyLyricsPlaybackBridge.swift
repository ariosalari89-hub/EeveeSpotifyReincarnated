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
    private var positionSeconds: Double = 0
    private var durationSeconds: Double = 0
    private var playbackRate: Double = 1
    private var isPlaying = false
    private var stateStamp = 0.0
    private var trackIdentifier: String?
    private var sequence: UInt64 = 0

    private init() {}

    func processStateChange(player: AnyObject, state: AnyObject) {
        let positionRaw = (safeRead(state, key: "position") as? NSNumber)?.doubleValue ?? 0
        let durationRaw = (safeRead(state, key: "duration") as? NSNumber)?.doubleValue ?? 0
        let rate = (safeRead(state, key: "playbackSpeed") as? NSNumber)?.doubleValue ?? 1
        let playing = (safeRead(state, key: "isPlaying") as? Bool) ?? false
        let track = safeRead(state, key: "track") as AnyObject?
        let uri = extractURI(from: track)
        let duration = normalizeSeconds(durationRaw, durationHint: durationRaw)
        let position = normalizeSeconds(positionRaw, durationHint: durationRaw)

        queue.async {
            self.player = player
            self.positionSeconds = max(0, position)
            self.durationSeconds = max(0, duration)
            self.playbackRate = rate > 0 ? rate : 1
            self.isPlaying = playing
            self.stateStamp = self.uptimeSeconds()
            if let uri, !uri.isEmpty { self.trackIdentifier = self.spotifyTrackID(from: uri) }
            self.sequence &+= 1
        }
    }

    func playbackPayload() -> [String: Any] {
        let nowPlaying = Thread.isMainThread ? MPNowPlayingInfoCenter.default().nowPlayingInfo : nil
        let fallbackPosition = (nowPlaying?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue
        let fallbackDuration = (nowPlaying?[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue
        let fallbackRate = (nowPlaying?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue

        return queue.sync {
            let stateIsFresh = stateStamp != 0 && uptimeSeconds() - stateStamp < 2
            let basePosition = stateIsFresh ? positionSeconds : (fallbackPosition ?? positionSeconds)
            let baseDuration = stateIsFresh ? durationSeconds : (fallbackDuration ?? durationSeconds)
            let baseRate = stateIsFresh ? playbackRate : max(0, fallbackRate ?? (isPlaying ? playbackRate : 0))
            let playing = stateIsFresh ? isPlaying : baseRate > 0
            let elapsed = stateIsFresh && stateStamp != 0 ? uptimeSeconds() - stateStamp : 0
            let estimated = playing ? basePosition + elapsed * baseRate : basePosition
            let bounded = baseDuration > 0 ? min(max(0, estimated), baseDuration) : max(0, estimated)
            return [
                "positionMs": Int(bounded * 1000),
                "durationMs": Int(baseDuration * 1000),
                "isPlaying": playing,
                "playbackRate": baseRate > 0 ? baseRate : 1,
                "trackId": trackIdentifier ?? "",
                "sequence": String(sequence)
            ]
        }
    }

    func currentTrackID() -> String? {
        if let track = statefulPlayer?.currentTrack() {
            let identifier = track.trackIdentifier
            if !identifier.isEmpty { return identifier }
        }
        return queue.sync { trackIdentifier }
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
        guard let player = capturedPlayer ?? statefulCandidate else {
            writeDebugLog("[SpicyRenderer] command \(command) rejected: no player")
            return false
        }

        if command == "seek", let seconds = value {
            return seek(player: player, seconds: max(0, seconds))
        }

        let names: [String]
        switch command {
        case "togglePlay": names = ["togglePlay", "togglePlayPause"]
        case "play": names = ["play"]
        case "pause": names = ["pause"]
        case "next": names = ["skipToNext", "skipToNextTrack"]
        case "previous": names = ["skipToPrevious", "skipToPreviousTrack", "back"]
        default: return false
        }

        guard let selector = names.lazy.map(NSSelectorFromString).first(where: { player.responds(to: $0) }) else {
            writeDebugLog("[SpicyRenderer] command \(command) unavailable on \(type(of: player))")
            return false
        }
        DispatchQueue.main.async { EeveeInvokeVoidNoArg(player, selector) }
        return true
    }

    private func seek(player: AnyObject, seconds: Double) -> Bool {
        let names = ["seekTo:", "seekToPosition:", "seekToPositionMs:", "seekToMs:"]
        guard let selector = names.lazy.map(NSSelectorFromString).first(where: { player.responds(to: $0) }),
              let method = class_getInstanceMethod(object_getClass(player), selector) else {
            return false
        }

        let argumentType: String = {
            guard let raw = method_copyArgumentType(method, 2) else { return "?" }
            defer { free(raw) }
            return String(cString: raw)
        }()
        let argument = argumentType == "d" ? seconds : seconds * 1000
        DispatchQueue.main.async { EeveeSBInvokeSeekDouble(player, selector, argument) }
        return true
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
