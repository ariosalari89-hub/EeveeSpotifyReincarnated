import Foundation

struct LocalAudioImportResult: Identifiable {
    enum Outcome {
        case copied(URL)
        case failed(String)
    }

    let id = UUID()
    let sourceName: String
    let outcome: Outcome

    var fileURL: URL? {
        if case .copied(let url) = outcome { return url }
        return nil
    }
}

/// Copies user-selected audio into the native local-song source.
/// Call away from the main thread; a returned file is copied, not necessarily indexed.
final class LocalAudioImporter {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func importFiles(_ urls: [URL]) -> [LocalAudioImportResult] {
        urls.map { source in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: destination)
                return LocalAudioImportResult(sourceName: source.lastPathComponent, outcome: .copied(destination))
            } catch {
                return LocalAudioImportResult(sourceName: source.lastPathComponent,
                                              outcome: .failed("Could not copy this audio file."))
            }
        }
    }
}
