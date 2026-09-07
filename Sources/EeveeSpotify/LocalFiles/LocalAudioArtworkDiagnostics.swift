import Foundation

final class LocalAudioArtworkDiagnostics {
    static let shared = LocalAudioArtworkDiagnostics(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("eevee-local-artwork-active.log"))

    private static let allowedCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._=-")
    private let fileURL: URL
    private let available: Bool
    private let queue = DispatchQueue(label: "EeveeSpotify.local-artwork-diagnostics", qos: .utility)
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var repetitions: [String: Int] = [:]
    private var count = 0
    private var limited = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        let header = "[LocalArtwork] build=v5.20-diagnostic format=1 started=\(Date().description)\n"
        do {
            try Data(header.utf8).write(to: fileURL, options: .atomic)
            available = true
        } catch {
            // Never export an older active file as this session's observations.
            available = false
        }
    }

    func record(_ event: String) {
        // Native/reader producers supply only route categories, class names,
        // booleans and counts. Reject raw URL/path syntax and multiline input
        // again at the file boundary; no ordinary player/UI sink accepts this.
        guard available, event.hasPrefix("native ") || event.hasPrefix("reader "),
              event.utf8.count <= 512,
              event.unicodeScalars.allSatisfy({ Self.allowedCharacters.contains($0) }) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !limited, repetitions[event, default: 0] < 3 else { return }
        guard count < 256 else {
            limited = true
            queue.async { self.append("[LocalArtwork] trace limit=reached\n") }
            return
        }
        repetitions[event, default: 0] += 1
        count += 1
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        let line = "[LocalArtwork] ms=\(milliseconds) \(event)\n"
        queue.async { self.append(line) }
    }

    func exportSnapshot() -> URL? {
        guard available else { return nil }
        return queue.sync {
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty,
                  data.count <= 192 * 1_024 else { return nil }
            let destination = fileURL.deletingLastPathComponent()
                .appendingPathComponent("eevee-local-artwork-diagnostics-\(UUID().uuidString).log")
            do {
                try data.write(to: destination, options: .atomic)
                return destination
            } catch { return nil }
        }
    }

    private func append(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch { /* Diagnostics must never interrupt image loading. */ }
    }
}
