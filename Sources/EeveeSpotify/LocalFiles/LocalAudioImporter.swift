import Foundation
import AVFoundation

enum LocalAudioImportFailure: String, Error {
    case notAFile = "local_audio_not_file"
    case emptyFile = "local_audio_empty"
    case unreadableAudio = "local_audio_unreadable"
    case cannotCopy = "local_audio_cannot_copy"
}

final class LocalAudioImportCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct LocalAudioImportProgress {
    let completedFiles: Int
    let totalFiles: Int
    var currentName: String? = nil
    var copiedBytes: Int64 = 0
    var totalBytes: Int64 = 0
}

struct LocalAudioImportResult: Identifiable {
    enum Outcome {
        case copied(URL)
        case alreadyPresent(URL)
        case failed(LocalAudioImportFailure)
        case cancelled
    }

    let id = UUID()
    let sourceName: String
    let outcome: Outcome

    var fileURL: URL? {
        switch outcome {
        case .copied(let url), .alreadyPresent(let url): return url
        case .failed, .cancelled: return nil
        }
    }
}

/// Copies user-selected audio into the native local-song source.
/// Call away from the main thread; a returned file is copied, not necessarily indexed.
final class LocalAudioImporter {
    private let directory: URL
    private enum Stopped: Error { case requested }

    init(directory: URL) {
        self.directory = directory
    }

    func importFiles(_ urls: [URL], cancellation: LocalAudioImportCancellation = LocalAudioImportCancellation(),
                     progress: (LocalAudioImportProgress) -> Void = { _ in }) -> [LocalAudioImportResult] {
        urls.enumerated().map { fileIndex, source in
            defer { progress(LocalAudioImportProgress(completedFiles: fileIndex + 1, totalFiles: urls.count)) }
            guard !cancellation.isCancelled else {
                return LocalAudioImportResult(sourceName: source.lastPathComponent, outcome: .cancelled)
            }
            do {
                guard source.isFileURL else { throw LocalAudioImportFailure.notAFile }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let stageDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("EeveeLocalAudioImport-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: stageDirectory) }
                let stage = stageDirectory.appendingPathComponent("audio").appendingPathExtension(source.pathExtension)
                try stageCopy(source, to: stage, cancellation: cancellation) { copied, total in
                    progress(LocalAudioImportProgress(completedFiles: fileIndex, totalFiles: urls.count,
                                                      currentName: source.lastPathComponent,
                                                      copiedBytes: copied, totalBytes: total))
                }
                try validateAudio(stage, cancellation: cancellation)
                var index = 1
                while true {
                    try checkCancellation(cancellation)
                    let suffix = index == 1 ? "" : " (\(index))"
                    let ext = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
                    let name = source.deletingPathExtension().lastPathComponent + suffix + ext
                    let destination = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        if FileManager.default.contentsEqual(atPath: stage.path, andPath: destination.path) {
                            return LocalAudioImportResult(sourceName: source.lastPathComponent, outcome: .alreadyPresent(destination))
                        }
                        index += 1
                        continue
                    }
                    do {
                        // Both locations are in the app's data volume. FileManager's
                        // non-replacing move publishes the complete file, never a partial copy.
                        try FileManager.default.moveItem(at: stage, to: destination)
                        return LocalAudioImportResult(sourceName: source.lastPathComponent, outcome: .copied(destination))
                    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                        index += 1
                    }
                }
            } catch is Stopped {
                return LocalAudioImportResult(sourceName: source.lastPathComponent, outcome: .cancelled)
            } catch {
                return LocalAudioImportResult(sourceName: source.lastPathComponent,
                                              outcome: .failed((error as? LocalAudioImportFailure) ?? .cannotCopy))
            }
        }
    }

    private func checkCancellation(_ cancellation: LocalAudioImportCancellation) throws {
        if cancellation.isCancelled { throw Stopped.requested }
    }

    private func regularFileSize(_ source: URL) throws -> Int64 {
        guard source.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LocalAudioImportFailure.notAFile
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw LocalAudioImportFailure.emptyFile
        }
        return size
    }

    private func stageCopy(_ source: URL, to stage: URL, cancellation: LocalAudioImportCancellation,
                           progress: (Int64, Int64) -> Void) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var copyResult: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
            copyResult = Result {
                let total = try regularFileSize(coordinated)
                try checkCancellation(cancellation)
                guard FileManager.default.createFile(atPath: stage.path, contents: nil) else {
                    throw LocalAudioImportFailure.cannotCopy
                }
                let reader = try FileHandle(forReadingFrom: coordinated)
                defer { try? reader.close() }
                let writer = try FileHandle(forWritingTo: stage)
                defer { try? writer.close() }
                var copied: Int64 = 0
                progress(copied, total)
                while true {
                    try checkCancellation(cancellation)
                    guard let data = try reader.read(upToCount: 1_048_576), !data.isEmpty else { break }
                    try writer.write(contentsOf: data)
                    copied += Int64(data.count)
                    progress(copied, total)
                }
                try checkCancellation(cancellation)
                guard copied == total else { throw LocalAudioImportFailure.cannotCopy }
                try writer.synchronize()
            }
        }
        if let coordinationError = coordinationError { throw coordinationError }
        guard let copyResult = copyResult else { throw LocalAudioImportFailure.cannotCopy }
        try copyResult.get()
    }

    private func validateAudio(_ source: URL, cancellation: LocalAudioImportCancellation) throws {
        do {
            let audio = try AVAudioFile(forReading: source)
            guard audio.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 8_192) else {
                throw LocalAudioImportFailure.unreadableAudio
            }
            var decodedFrames: Int64 = 0
            while audio.framePosition < audio.length {
                try checkCancellation(cancellation)
                let remaining = AVAudioFrameCount(min(Int64(buffer.frameCapacity), audio.length - audio.framePosition))
                try audio.read(into: buffer, frameCount: remaining)
                guard buffer.frameLength > 0 else { throw LocalAudioImportFailure.unreadableAudio }
                decodedFrames += Int64(buffer.frameLength)
            }
            guard decodedFrames > 0 else { throw LocalAudioImportFailure.unreadableAudio }
        } catch is Stopped {
            throw Stopped.requested
        } catch {
            throw LocalAudioImportFailure.unreadableAudio
        }
    }
}
