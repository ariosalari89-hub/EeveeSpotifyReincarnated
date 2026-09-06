import Foundation

struct LocalAudioImportResult: Identifiable {
    enum Outcome {
        case copied(URL)
        case alreadyPresent(URL)
        case failed(String)
    }

    let id = UUID()
    let sourceName: String
    let outcome: Outcome

    var fileURL: URL? {
        switch outcome {
        case .copied(let url), .alreadyPresent(let url): return url
        case .failed: return nil
        }
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
                var index = 1
                while true {
                    let suffix = index == 1 ? "" : " (\(index))"
                    let ext = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
                    let name = source.deletingPathExtension().lastPathComponent + suffix + ext
                    let destination = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        if FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path) {
                            return LocalAudioImportResult(sourceName: source.lastPathComponent, outcome: .alreadyPresent(destination))
                        }
                        index += 1
                        continue
                    }
                    do {
                        try FileManager.default.copyItem(at: source, to: destination)
                        return LocalAudioImportResult(sourceName: source.lastPathComponent, outcome: .copied(destination))
                    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                        index += 1
                    }
                }
            } catch {
                return LocalAudioImportResult(sourceName: source.lastPathComponent,
                                              outcome: .failed("Could not copy this audio file."))
            }
        }
    }
}
