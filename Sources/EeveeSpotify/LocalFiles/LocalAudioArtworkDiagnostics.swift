import Foundation

final class LocalAudioArtworkDiagnostics {
    static let shared = LocalAudioArtworkDiagnostics(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("eevee-local-artwork-active.log"))

    init(fileURL: URL) {}
    func record(_ event: String) {}
    func exportSnapshot() -> URL? { nil }
}
