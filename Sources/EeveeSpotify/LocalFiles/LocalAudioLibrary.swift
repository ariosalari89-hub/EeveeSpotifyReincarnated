import Foundation
import AVFoundation

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
        []
    }
}
