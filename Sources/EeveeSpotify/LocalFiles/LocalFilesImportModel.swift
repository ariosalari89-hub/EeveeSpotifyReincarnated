import Foundation
import Combine

/// UI state is published only on the main thread. The shared model, not a page,
/// owns the work so ordinary settings navigation cannot abandon selected files.
final class LocalFilesImportModel: ObservableObject {
    struct State {
        var isImporting = false
        var isStopping = false
        var progress = LocalAudioImportProgress(completedFiles: 0, totalFiles: 0)
        var results: [LocalAudioImportResult] = []
    }

    static let shared = LocalFilesImportModel(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)

    @Published private(set) var state = State()
    private let importer: LocalAudioImporter?
    private let queue = DispatchQueue(label: "EeveeSpotify.local-audio-import", qos: .userInitiated)
    private var activeCancellation: LocalAudioImportCancellation?

    init(directory: URL?) {
        importer = directory.map { LocalAudioImporter(directory: $0) }
    }

    func importSelection(_ urls: [URL]) {
        precondition(Thread.isMainThread)
        guard !state.isImporting, !urls.isEmpty else { return }
        let cancellation = LocalAudioImportCancellation()
        activeCancellation = cancellation
        state = State(isImporting: true, progress: LocalAudioImportProgress(completedFiles: 0, totalFiles: urls.count))
        queue.async { [self] in
            var lastUpdate = Date.distantPast
            var lastCompleted = -1
            var lastName: String?
            let results = importer?.importFiles(urls, cancellation: cancellation) { progress in
                // Forward measured work at a bounded rate; never animate invented progress.
                let now = Date()
                guard progress.completedFiles != lastCompleted || progress.currentName != lastName ||
                        now.timeIntervalSince(lastUpdate) >= 0.1 else { return }
                lastUpdate = now
                lastCompleted = progress.completedFiles
                lastName = progress.currentName
                DispatchQueue.main.async { [self] in
                    state.progress = progress
                }
            } ?? urls.map { LocalAudioImportResult(sourceName: $0.lastPathComponent, outcome: .failed(.cannotCopy)) }
            DispatchQueue.main.async { [self] in
                activeCancellation = nil
                state = State(progress: LocalAudioImportProgress(completedFiles: urls.count, totalFiles: urls.count), results: results)
            }
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        guard state.isImporting, !state.isStopping else { return }
        activeCancellation?.cancel()
        state.isStopping = true
    }
}
