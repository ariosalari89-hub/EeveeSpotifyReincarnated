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

    init(directory: URL) {
        self.directory = directory
    }

    func importFiles(_ urls: [URL], cancellation: LocalAudioImportCancellation = LocalAudioImportCancellation(),
                     progress: (LocalAudioImportProgress) -> Void = { _ in }) -> [LocalAudioImportResult] {
        urls.enumerated().map { index, source in
            defer { progress(LocalAudioImportProgress(completedFiles: index + 1, totalFiles: urls.count)) }
            guard !cancellation.isCancelled else {
                return LocalAudioImportResult(sourceName: source.lastPathComponent, outcome: .cancelled)
            }
            do {
                try validate(source)
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
                                              outcome: .failed((error as? LocalAudioImportFailure) ?? .cannotCopy))
            }
        }
    }

    private func validate(_ source: URL) throws {
        guard source.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LocalAudioImportFailure.notAFile
        }
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw LocalAudioImportFailure.emptyFile
        }
        do {
            let audio = try AVAudioFile(forReading: source)
            guard audio.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 8_192) else {
                throw LocalAudioImportFailure.unreadableAudio
            }
            var decodedFrames: Int64 = 0
            while audio.framePosition < audio.length {
                let remaining = AVAudioFrameCount(min(Int64(buffer.frameCapacity), audio.length - audio.framePosition))
                try audio.read(into: buffer, frameCount: remaining)
                guard buffer.frameLength > 0 else { throw LocalAudioImportFailure.unreadableAudio }
                decodedFrames += Int64(buffer.frameLength)
            }
            guard decodedFrames > 0 else { throw LocalAudioImportFailure.unreadableAudio }
        } catch {
            throw LocalAudioImportFailure.unreadableAudio
        }
    }
}
