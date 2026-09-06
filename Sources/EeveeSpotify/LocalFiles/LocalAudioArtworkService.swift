import Foundation
import AVFoundation

final class LocalAudioArtworkService {
    private static let marker = "/.eevee-local-artwork-v1/"
    private let library: LocalAudioLibrary
    private let directory: URL
    private let queue = DispatchQueue(label: "EeveeSpotify.local-artwork", qos: .utility)

    init(directory: URL) {
        library = LocalAudioLibrary(directory: directory)
        self.directory = directory.resolvingSymlinksInPath()
    }

    func imageURL(forTrackURI uri: String) -> URL? {
        guard LocalTrackIdentity(uri) != nil else { return nil }
        // Escape every payload byte. The native factory splits on ':' and
        // excludes raw 'ipod-library', which can also occur in a song title.
        let payload = (Self.marker + uri).utf8.map { String(format: "%%%02X", $0) }.joined()
        return URL(string: "spotify:localfileimage:" + payload)
    }

    @discardableResult
    func load(_ url: URL, isCancelled: @escaping () -> Bool, completion: @escaping (Data?) -> Void) -> Bool {
        guard let request = request(for: url) else { return false }
        queue.async { [library] in
            guard !isCancelled(), let files = try? library.files() else { completion(nil); return }
            var matches: [LocalAudioFile] = []
            for file in files {
                guard !isCancelled() else { completion(nil); return }
                switch request {
                case .track(let identity):
                    if identity.matches(file) { matches.append(file) }
                case .file(let location):
                    if location.resolvingSymlinksInPath() == file.fileURL.resolvingSymlinksInPath() { matches.append(file) }
                }
                if matches.count > 1 { completion(nil); return }
            }
            guard let file = matches.first else { completion(nil); return }
            var error: NSError?
            var artwork: Data?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file.fileURL, options: [], error: &error) { location in
                guard !isCancelled(), location.resolvingSymlinksInPath() == file.fileURL.resolvingSymlinksInPath(),
                      (try? library.files().contains(file)) == true else { return }
                artwork = LocalAudioArtworkReader.artwork(in: location)
                if (try? library.files().contains(file)) != true { artwork = nil }
            }
            completion(isCancelled() ? nil : artwork)
        }
        return true
    }

    private enum Request { case track(LocalTrackIdentity), file(URL) }

    private func request(for url: URL) -> Request? {
        let parts = url.absoluteString.components(separatedBy: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "localfileimage",
              let payload = parts[2].removingPercentEncoding else { return nil }
        if payload.hasPrefix(Self.marker) {
            return LocalTrackIdentity(String(payload.dropFirst(Self.marker.count))).map(Request.track)
        }
        guard payload.hasPrefix("/") else { return nil }
        let location = URL(fileURLWithPath: payload).standardizedFileURL
        guard location.deletingLastPathComponent().resolvingSymlinksInPath() == directory else { return nil }
        return .file(location)
    }
}

private struct LocalTrackIdentity {
    let artist: String
    let album: String
    let title: String
    let seconds: Int

    init?(_ uri: String) {
        guard uri.utf8.count <= 16_384 else { return nil }
        let parts = uri.components(separatedBy: ":")
        guard parts.count == 6, parts[0] == "spotify", parts[1] == "local",
              let seconds = Int(parts[5]), seconds >= 0,
              let artist = Self.decode(parts[2]), let album = Self.decode(parts[3]),
              let title = Self.decode(parts[4]) else { return nil }
        self.artist = artist
        self.album = album
        self.title = title
        self.seconds = seconds
    }

    private static func decode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding?.precomposedStringWithCanonicalMapping
    }

    func matches(_ file: LocalAudioFile) -> Bool {
        let asset = AVURLAsset(url: file.fileURL)
        let metadata = asset.commonMetadata
        func text(_ key: AVMetadataKey) -> String {
            (metadata.first { $0.commonKey == key }?.stringValue ?? "").precomposedStringWithCanonicalMapping
        }
        let embeddedTitle = text(.commonKeyTitle)
        let candidateTitle = embeddedTitle.isEmpty && !title.isEmpty
            ? file.fileURL.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping : embeddedTitle
        let duration = CMTimeGetSeconds(asset.duration)
        return artist == text(.commonKeyArtist) && album == text(.commonKeyAlbumName) && title == candidateTitle &&
            duration.isFinite && abs(duration - Double(seconds)) < 1
    }
}
