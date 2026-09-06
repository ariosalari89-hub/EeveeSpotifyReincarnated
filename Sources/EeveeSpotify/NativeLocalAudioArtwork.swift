import Foundation
import EeveeSpotifyC

enum NativeLocalAudioArtwork {
    static func install() -> Bool {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let service = LocalAudioArtworkService(directory: directory)
        return EeveeLocalAudioInstallArtwork({ uri in
            service.imageURL(forTrackURI: uri)?.absoluteString
        }, { url, cancelled, completion in
            service.load(url, isCancelled: cancelled, completion: completion)
        })
    }
}
