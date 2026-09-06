import Foundation

final class LocalAudioArtworkService {
    init(directory: URL) {}

    func imageURL(forTrackURI uri: String) -> URL? { nil }

    @discardableResult
    func load(_ url: URL, isCancelled: @escaping () -> Bool, completion: @escaping (Data?) -> Void) -> Bool {
        false
    }
}
