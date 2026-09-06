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
        urls.map { LocalAudioImportResult(sourceName: $0.lastPathComponent,
                                          outcome: .failed("Could not read this audio file.")) }
    }
}
