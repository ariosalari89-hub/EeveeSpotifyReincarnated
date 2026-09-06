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
        var files: [LocalAudioFile] = []
        var isLoadingFiles = false
        var filesError: String?
    }

    static let shared = LocalFilesImportModel(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)

    @Published private(set) var state = State()
    private let importer: LocalAudioImporter?
    private let library: LocalAudioLibrary?
    private let queue = DispatchQueue(label: "EeveeSpotify.local-audio-import", qos: .userInitiated)
    private var activeCancellation: LocalAudioImportCancellation?

    init(directory: URL?) {
        importer = directory.map { LocalAudioImporter(directory: $0) }
        library = directory.map { LocalAudioLibrary(directory: $0) }
    }

    func refreshFiles() {
        precondition(Thread.isMainThread)
        guard !state.isLoadingFiles, !state.isImporting else { return }
        state.isLoadingFiles = true
        state.filesError = nil
        queue.async { [self] in
            let result = Result { () throws -> [LocalAudioFile] in
                guard let library = library else { throw LocalAudioLibraryFailure.cannotRead }
                return try library.files()
            }
            DispatchQueue.main.async { [self] in
                state.isLoadingFiles = false
                switch result {
                case .success(let files): state.files = files
                case .failure: state.filesError = LocalAudioLibraryFailure.cannotRead.rawValue
                }
            }
        }
    }

    func importSelection(_ urls: [URL]) {
        precondition(Thread.isMainThread)
        guard !state.isImporting, !urls.isEmpty else { return }
        let cancellation = LocalAudioImportCancellation()
        activeCancellation = cancellation
        state.isImporting = true
        state.isStopping = false
        state.progress = LocalAudioImportProgress(completedFiles: 0, totalFiles: urls.count)
        state.results = []
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
                state.isImporting = false
                state.isStopping = false
                state.progress = LocalAudioImportProgress(completedFiles: urls.count, totalFiles: urls.count)
                state.results = results
                refreshFiles()
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
