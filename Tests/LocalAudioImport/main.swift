import Foundation
import AVFoundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(description: message) }
}

func makeAudio(at url: URL, value: Float = 0.125) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
    buffer.frameLength = 4_410
    for frame in 0..<4_410 { buffer.floatChannelData![0][frame] = value }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

func withDirectories(_ test: (URL, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-audio-test-" + UUID().uuidString)
    let input = root.appendingPathComponent("input", isDirectory: true)
    let output = root.appendingPathComponent("Documents", isDirectory: true)
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try test(input, output)
}

do {
    try withDirectories { input, output in
        let original = input.appendingPathComponent("First song.wav")
        try makeAudio(at: original)
        let originalBytes = try Data(contentsOf: original)
        let result = LocalAudioImporter(directory: output).importFiles([original])
        try expect(result.count == 1, "one selected file must produce one result")
        guard case .copied(let copied) = result[0].outcome else {
            throw TestFailure(description: "selected playable audio must be reported as copied")
        }
        try expect(copied == output.appendingPathComponent("First song.wav"), "the returned song belongs in the native Documents source")
        let copiedBytes = try Data(contentsOf: copied)
        let sourceBytes = try Data(contentsOf: original)
        try expect(copiedBytes == originalBytes && sourceBytes == originalBytes, "import must preserve both the original audio and its exact copied bytes")
        let playerInput = try AVAudioFile(forReading: copied)
        let buffer = AVAudioPCMBuffer(pcmFormat: playerInput.processingFormat, frameCapacity: 4_410)!
        try playerInput.read(into: buffer)
        try expect(buffer.frameLength == 4_410, "the output must be consumable by the platform audio reader")
        print("PASS: selected audio becomes a playable, byte-preserving Documents copy")
    }
    print("PASS")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
