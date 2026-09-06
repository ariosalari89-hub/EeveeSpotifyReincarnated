import Foundation
import AVFoundation

enum LocalAudioLibraryFailure: String, Error {
    case cannotRead = "local_files_load_failed"
    case invalidName = "local_files_invalid_name"
    case changed = "local_files_changed"
    case nameExists = "local_files_name_exists"
    case cannotRename = "local_files_rename_failed"
    case cannotRemove = "local_files_remove_failed"
    case busy = "local_files_busy"
}

struct LocalAudioFile: Identifiable, Equatable {
    let id: String
    let fileURL: URL
    let size: Int64
    let modified: Date
    let created: Date

    var name: String { fileURL.lastPathComponent }
}

final class LocalAudioLibrary {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    func files() throws -> [LocalAudioFile] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        guard let attributes = try? manager.attributesOfItem(atPath: directory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw LocalAudioLibraryFailure.cannotRead
        }
        let urls = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard url.deletingLastPathComponent().standardizedFileURL == directory,
                  let attributes = try? manager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let created = attributes[.creationDate] as? Date,
                  let audio = try? AVAudioFile(forReading: url), audio.length > 0 else { return nil }
            return LocalAudioFile(id: device.stringValue + ":" + inode.stringValue, fileURL: url,
                                  size: size.int64Value, modified: modified, created: created)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func rename(_ file: LocalAudioFile, toStem stem: String) throws -> LocalAudioFile {
        let name = stem + (file.fileURL.pathExtension.isEmpty ? "" : "." + file.fileURL.pathExtension)
        guard !stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !stem.hasPrefix("."), !stem.contains("/"), !stem.contains("\\"), !stem.contains(":"),
              stem.rangeOfCharacter(from: .controlCharacters) == nil, name.utf8.count <= 255 else {
            throw LocalAudioLibraryFailure.invalidName
        }
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<LocalAudioFile, Error>?
        coordinator.coordinate(writingItemAt: file.fileURL, options: .forMoving,
                               writingItemAt: destination, options: [], error: &coordinationError) { source, target in
            outcome = Result {
                try validate(file, at: source)
                if file.name == name { return file }
                // attributesOfItem also detects dangling symlinks; never replace a name.
                guard (try? FileManager.default.attributesOfItem(atPath: target.path)) == nil else {
                    throw LocalAudioLibraryFailure.nameExists
                }
                coordinator.item(at: source, willMoveTo: target)
                try FileManager.default.moveItem(at: source, to: target)
                coordinator.item(at: source, didMoveTo: target)
                guard let renamed = try files().first(where: { $0.id == file.id && $0.name == name }) else {
                    throw LocalAudioLibraryFailure.cannotRead
                }
                return renamed
            }
        }
        if let outcome = outcome { return try outcome.get() }
        throw coordinationError ?? LocalAudioLibraryFailure.cannotRename as Error
    }

    private func validate(_ file: LocalAudioFile, at url: URL) throws {
        guard url.resolvingSymlinksInPath() == file.fileURL.resolvingSymlinksInPath(),
              let current = try files().first(where: { $0.id == file.id && $0.name == file.name }),
              current.size == file.size, current.modified == file.modified, current.created == file.created,
              current.fileURL.resolvingSymlinksInPath() == file.fileURL.resolvingSymlinksInPath() else {
            throw LocalAudioLibraryFailure.changed
        }
    }

    func remove(_ file: LocalAudioFile) throws {
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file.fileURL, options: .forDeleting,
                                                         error: &coordinationError) { target in
            outcome = Result {
                try validate(file, at: target)
                try FileManager.default.removeItem(at: target)
            }
        }
        if let outcome = outcome { return try outcome.get() }
        throw coordinationError ?? LocalAudioLibraryFailure.cannotRemove as Error
    }
}
