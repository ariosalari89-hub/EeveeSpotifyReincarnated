import Foundation
import MediaPlayer
import UIKit

// Spotify is the external boundary. Compile the shipping bridge and clock;
// supply the verified Objective-C state/track selectors, not a second bridge.
var statefulPlayer: StatefulPlayerImplementation?
var capturedTrackTitle: String?
var capturedArtistName: String?
var capturedTrackId: String?
func writeDebugLog(_ message: String) { print(message) }

@objc final class MetadataTrack: NSObject {
    @objc dynamic var URI: NSURL
    @objc dynamic var metadata: [String: String]
    @objc var trackTitle: String { metadata["title"] ?? "" }
    @objc var artistName: String { metadata["artist_name"] ?? "" }
    @objc var albumTitle: String { metadata["album_title"] ?? "" }
    init(id: String, metadata: [String: String]) {
        self.URI = NSURL(string: "spotify:track:\(id)")!
        self.metadata = metadata
    }
}

@objc final class MetadataState: NSObject {
    @objc dynamic var track: MetadataTrack
    @objc dynamic var position: Double = 62
    @objc dynamic var duration: Double = 221
    @objc dynamic var isPlaying = true
    @objc dynamic var isPaused = false
    @objc dynamic var isLoading = false
    @objc dynamic var isBuffering = false
    @objc dynamic var playbackSpeed: Double = 1
    @objc dynamic var timestamp = NSDate()
    @objc dynamic var playbackId: String
    init(track: MetadataTrack) { self.track = track; self.playbackId = track.URI.absoluteString! }
}

@objc(SPTEsperantoPlayer) final class MetadataPlayer: NSObject {
    @objc dynamic var state: MetadataState
    init(state: MetadataState) { self.state = state }
}

let bridge = SpicyLyricsPlaybackBridge.shared
let track = MetadataTrack(id: "metadata-a", metadata: [
    "title": "Current song", "artist_name": "Current artist", "album_title": "Current album",
    "image_xlarge_url": "spotify:image:0123456789abcdef"
])
let player = MetadataPlayer(state: MetadataState(track: track))
bridge.processStateChange(player: player, state: player.state)
let payload = bridge.sessionPayload()
let presentation = payload?["track"] as? [String: Any] ?? [:]
let pass = presentation["title"] as? String == "Current song"
    && presentation["artist"] as? String == "Current artist"
    && presentation["artwork"] as? String == "https://i.scdn.co/image/0123456789abcdef"
print("\(pass ? "PASS" : "FAIL") metadata follows the authoritative observer even when the legacy player was never captured")
print("title=\(presentation["title"] ?? "nil") artist=\(presentation["artist"] ?? "nil") artwork=\(presentation["artwork"] ?? "nil")")
guard pass else { exit(1) }

track.metadata = ["album_title": "Updated album"]
player.state.timestamp = NSDate()
let partial = bridge.sessionPayload()?["track"] as? [String: Any] ?? [:]
let partialPass = partial["title"] as? String == "Current song"
    && partial["artist"] as? String == "Current artist"
    && partial["album"] as? String == "Updated album"
    && partial["artwork"] as? String == "https://i.scdn.co/image/0123456789abcdef"
print("\(partialPass ? "PASS" : "FAIL") partial metadata updates retain known details only for the current song")
print("title=\(partial["title"] ?? "nil") artist=\(partial["artist"] ?? "nil") album=\(partial["album"] ?? "nil") artwork=\(partial["artwork"] ?? "nil")")
guard partialPass else { exit(1) }

let emptyNext = MetadataTrack(id: "metadata-b", metadata: [:])
player.state = MetadataState(track: emptyNext)
capturedTrackId = "metadata-a"
capturedTrackTitle = "Stale captured song"
capturedArtistName = "Stale captured artist"
let next = bridge.sessionPayload()?["track"] as? [String: Any] ?? [:]
let nextPass = next["id"] as? String == "metadata-b"
    && next["title"] as? String == "Unknown track"
    && next["artist"] as? String == "Unknown artist"
    && next["artwork"] as? String == ""
print("\(nextPass ? "PASS" : "FAIL") a new song never inherits the prior song's cached or captured details")
guard nextPass else { exit(1) }

emptyNext.metadata = ["title": "Next song", "artist_name": "Next artist", "image_url": "https://i.scdn.co/image/next"]
player.state.timestamp = NSDate()
let late = bridge.sessionPayload()?["track"] as? [String: Any] ?? [:]
let latePass = late["title"] as? String == "Next song"
    && late["artist"] as? String == "Next artist"
    && late["artwork"] as? String == "https://i.scdn.co/image/next"
print("\(latePass ? "PASS" : "FAIL") late-arriving current-song metadata replaces the unavailable state")
guard latePass else { exit(1) }

emptyNext.metadata = ["title": "Corrected song title", "artist_name": "Corrected artist", "image_url": "https://i.scdn.co/image/replaced"]
player.state.timestamp = NSDate()
let corrected = bridge.sessionPayload()?["track"] as? [String: Any] ?? [:]
let correctedPass = corrected["title"] as? String == "Corrected song title"
    && corrected["artist"] as? String == "Corrected artist"
    && corrected["artwork"] as? String == "https://i.scdn.co/image/replaced"
print("\(correctedPass ? "PASS" : "FAIL") real current-song corrections replace the cached presentation")
exit(correctedPass ? 0 : 1)
