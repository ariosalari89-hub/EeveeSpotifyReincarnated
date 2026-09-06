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

func tryAudioFrames(_ url: URL) -> AVAudioFramePosition? {
    try? AVAudioFile(forReading: url).length
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
    try withDirectories { input, output in
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let original = input.appendingPathComponent("Shared title.wav")
        let existing = output.appendingPathComponent("Shared title.wav")
        try makeAudio(at: original, value: 0.25)
        try makeAudio(at: existing, value: 0.75)
        let existingBytes = try Data(contentsOf: existing)
        let result = LocalAudioImporter(directory: output).importFiles([original])
        guard let copied = result.first?.fileURL else {
            throw TestFailure(description: "a different song with an existing name must receive its own copy")
        }
        try expect(copied.lastPathComponent == "Shared title (2).wav", "a name collision must use a distinct visible filename")
        let preservedBytes = try Data(contentsOf: existing)
        let copiedBytes = try Data(contentsOf: copied)
        let sourceBytes = try Data(contentsOf: original)
        try expect(preservedBytes == existingBytes && copiedBytes == sourceBytes, "neither colliding song may be overwritten")
        print("PASS: different songs with the same filename both survive")
    }
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Repeat.wav")
        try makeAudio(at: original)
        let importer = LocalAudioImporter(directory: output)
        let first = importer.importFiles([original])
        let repeated = importer.importFiles([original])
        guard case .alreadyPresent(let sameFile) = repeated[0].outcome else {
            throw TestFailure(description: "reimporting identical audio must report already present, not copy it again")
        }
        try expect(sameFile == first[0].fileURL, "reimport must return the existing playable file")
        let files = try FileManager.default.contentsOfDirectory(atPath: output.path)
        try expect(files == ["Repeat.wav"], "reimport must not create a second song file")
        print("PASS: repeated selection reports already present without making another copy")
    }
    try withDirectories { input, output in
        let playable = input.appendingPathComponent("Keep me.wav")
        let fake = input.appendingPathComponent("Not audio.wav")
        let empty = input.appendingPathComponent("Empty.wav")
        let missing = input.appendingPathComponent("Missing.wav")
        let folder = input.appendingPathComponent("Folder.wav")
        let link = input.appendingPathComponent("Link.wav")
        try makeAudio(at: playable)
        try Data("This is not an audio file".utf8).write(to: fake)
        try Data().write(to: empty)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: playable)
        let results = LocalAudioImporter(directory: output).importFiles([fake, empty, missing, folder, link, playable])
        try expect(results.count == 6, "mixed selections need an individual result for every item")
        try expect(results.prefix(5).allSatisfy { if case .failed = $0.outcome { return true }; return false },
                   "invalid, empty, missing, directory and symbolic-link selections must be rejected as failed")
        guard case .copied(let song) = results[5].outcome else {
            throw TestFailure(description: "a failed item must not discard another selected song")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: output.path)
        try expect(files == ["Keep me.wav"], "only complete playable audio may enter the native song source")
        try expect(tryAudioFrames(song) == 4_410, "the successful part of a mixed batch remains readable")
        print("PASS: invalid inputs fail individually while valid selected audio survives")
    }
    print("PASS")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
