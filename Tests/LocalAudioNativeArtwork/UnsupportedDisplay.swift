import Foundation
import EeveeSpotifyC

@main
struct UnsupportedArtworkDisplayObservers {
    static func main() {
        var events: [String] = []
        let installed = EeveeLocalAudioInstallArtworkWithDiagnostics({ _ in nil }, { _, _, _ in false }, { events.append($0) })
        let url = URL(string: "spotify:localfileimage:PrivateCanary:PrivateCanary:PrivateCanary:0")!
        let error = NSError(domain: "PrivateCanary-domain", code: 74, userInfo: nil)
        guard installed, events.contains("native install metadata=1 legacy=1 core=1 remote=1"),
              events.contains("native display install getters=3 consumer=0"),
              events.contains("native view install cover=0 legacy=0 bar=1 encore=1"),
              EeveeArtworkFixtureConsumerForwarding(url, NSObject(), error), EeveeArtworkFixtureUnsupportedViews(),
              !events.contains(where: { $0.hasPrefix("native display stage=consumer-") || $0.hasPrefix("native view surface=cover ") }) else {
            fputs("FAIL: incompatible display ABIs must disable only their observers and preserve native callbacks, views and artwork adapters\n", stderr)
            exit(1)
        }
        print("PASS: incompatible display ABIs preserve native callback and view effects without disabling compatible observers or artwork adapters")
    }
}
