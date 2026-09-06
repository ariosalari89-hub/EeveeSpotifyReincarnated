import Foundation
import AVFoundation

enum LocalAudioLibraryFailure: String, Error {
    case cannotRead = "local_files_load_failed"
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
        throw LocalAudioLibraryFailure.cannotRead
    }
}
