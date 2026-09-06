import Foundation
import EeveeSpotifyC

@main
struct UnsupportedArtworkABI {
    static func main() {
        let installed = EeveeLocalAudioInstallArtwork({ _ in "spotify:localfileimage:unused" }, { _, _, _ in false })
        let values: [String: Any] = ["title": "Unchanged"]
        let track = EeveeArtworkFixtureTrack("spotify:local:Artist:Album:Title:0", values)
        let request = EeveeArtworkFixtureRequest(URL(string: "spotify:localfileimage:unused")!)
        EeveeArtworkFixtureLoad(request)
        guard !installed, NSDictionary(dictionary: EeveeArtworkFixtureMetadata(track)).isEqual(to: values),
              EeveeArtworkFixtureOriginalLoads(request) == 1 else {
            fputs("FAIL: an incompatible native image-loader signature must decline installation without partial hooks\n", stderr)
            exit(1)
        }
        print("PASS: incompatible native artwork ABI declines installation without partial hooks")
    }
}
