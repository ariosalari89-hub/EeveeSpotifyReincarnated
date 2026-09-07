import Foundation
import EeveeSpotifyC

@main
struct UnsupportedRemoteArtworkObserver {
    static func main() {
        var events: [String] = []
        let installed = EeveeLocalAudioInstallArtworkWithDiagnostics({ _ in nil }, { _, _, _ in false }, { events.append($0) })
        let url = URL(string: "https://example.invalid/PrivateCanary")!
        let data = Data([7, 1])
        let request = EeveeArtworkFixtureCoreRequest(url, data)
        let error = NSError(domain: "PrivateCanary-domain", code: 73, userInfo: nil)
        guard installed, events.contains("native install metadata=1 legacy=1 core=1 remote=0"),
              EeveeArtworkFixtureRemoteForwarding(url, request, data, error),
              !events.contains(where: { $0.hasPrefix("native remote ") }) else {
            fputs("FAIL: an incompatible remote image ABI must disable only its observer and preserve all native arguments\n", stderr)
            exit(1)
        }
        print("PASS: an incompatible remote image ABI declines passive observers without disabling the existing artwork adapter")
    }
}
