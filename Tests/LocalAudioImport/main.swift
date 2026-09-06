import Foundation
import AVFoundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(description: message) }
}

func makeAudio(at url: URL, value: Float = 0.125, frames: AVAudioFrameCount = 4_410) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = value }
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
            throw TestFailure(description: "selected playable audio must be reported as copied; outcome=\(result[0].outcome)")
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
    try withDirectories { input, output in
        let first = input.appendingPathComponent("Completed.wav")
        let second = input.appendingPathComponent("Not started.wav")
        try makeAudio(at: first)
        try makeAudio(at: second)
        let cancellation = LocalAudioImportCancellation()
        let results = LocalAudioImporter(directory: output).importFiles([first, second], cancellation: cancellation) { progress in
            if progress.completedFiles == 1 { cancellation.cancel() }
        }
        guard case .copied(let kept) = results[0].outcome, case .cancelled = results[1].outcome else {
            throw TestFailure(description: "stopping after one completed song must keep it and cancel the unstarted song")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: output.path)
        try expect(files == ["Completed.wav"] && tryAudioFrames(kept) == 4_410,
                   "cancellation retains completed playable output without adding unfinished selections")
        print("PASS: stop retains the completed song and reports unstarted items as cancelled")
    }
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Stop during copy.wav")
        try makeAudio(at: original, frames: 800_000)
        let originalBytes = try Data(contentsOf: original)
        let cancellation = LocalAudioImportCancellation()
        var observedByteProgress = false
        var exposedIncompleteSong = false
        let results = LocalAudioImporter(directory: output).importFiles([original], cancellation: cancellation) { progress in
            if progress.copiedBytes > 0 && progress.copiedBytes < progress.totalBytes {
                observedByteProgress = true
                exposedIncompleteSong = !((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []).isEmpty
                cancellation.cancel()
            }
        }
        guard observedByteProgress, case .cancelled = results[0].outcome else {
            throw TestFailure(description: "a running file copy must expose real progress and be stoppable before it commits")
        }
        let finalFiles = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        let preserved = try Data(contentsOf: original)
        try expect(!exposedIncompleteSong && finalFiles.isEmpty && preserved == originalBytes,
                   "an interrupted file must never appear in the native song folder or modify the original")
        print("PASS: a running copy can stop without exposing a partial song")
    }
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Linked name.wav")
        try makeAudio(at: original)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let existingLink = output.appendingPathComponent("Linked name.wav")
        try FileManager.default.createSymbolicLink(at: existingLink, withDestinationURL: original)
        let results = LocalAudioImporter(directory: output).importFiles([original])
        guard case .copied(let copied) = results[0].outcome else {
            throw TestFailure(description: "a same-name symbolic link must not stand in for a durable local song copy")
        }
        try expect(copied.lastPathComponent == "Linked name (2).wav" &&
                   copied.resolvingSymlinksInPath().deletingLastPathComponent() == output.resolvingSymlinksInPath(),
                   "a copied song must remain inside the native source even when an existing name is a link")
        try expect(FileManager.default.fileExists(atPath: original.path), "import must not modify a linked external original")
        print("PASS: existing symbolic links cannot redirect a local song's returned output")
    }
    try withDirectories { input, output in
        let name = String(repeating: "音", count: 83) + ".wav"
        let original = input.appendingPathComponent(name)
        try makeAudio(at: original, value: 0.125)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try makeAudio(at: output.appendingPathComponent(name), value: 0.75)
        let results = LocalAudioImporter(directory: output).importFiles([original])
        guard case .copied(let copied) = results[0].outcome else {
            throw TestFailure(description: "a long Unicode song name must still get a non-overwriting copy")
        }
        try expect(copied.lastPathComponent == String(repeating: "音", count: 82) + " (2).wav",
                   "collision naming must leave room for the suffix within 255 UTF-8 bytes without breaking Unicode")
        try expect(tryAudioFrames(copied) == 4_410, "a shortened filename must retain playable audio and its extension")
        print("PASS: long Unicode collision names are byte-bounded and remain readable")
    }
    try withDirectories { input, output in
        let mp3 = input.appendingPathComponent("Synthetic.mp3")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "Tests/LocalAudioImport/Fixtures/synthetic-tone.mp3"), to: mp3)
        let aac = input.appendingPathComponent("Synthetic.m4a")
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 11_025)!
        buffer.frameLength = 11_025
        for index in 0..<11_025 { buffer.floatChannelData![0][index] = 0.125 }
        do {
            let encoder = try AVAudioFile(forWriting: aac, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try encoder.write(from: buffer)
        }
        for source in [mp3, aac] {
            let before = try Data(contentsOf: source)
            let results = LocalAudioImporter(directory: output).importFiles([source])
            guard case .copied(let copied) = results[0].outcome else {
                throw TestFailure(description: "supported \(source.pathExtension) audio must import without conversion: \(results[0].outcome)")
            }
            let audio = try AVAudioFile(forReading: copied)
            let decoded = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(min(1_024, audio.length)))!
            try audio.read(into: decoded)
            let after = try Data(contentsOf: copied)
            let original = try Data(contentsOf: source)
            try expect(decoded.frameLength > 0 && before == after && before == original,
                       "compressed audio must remain decodable and byte-for-byte unchanged")
            print("PASS: \(source.pathExtension) imports without transcoding (\(audio.length) readable frames)")
        }
    }
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Canonical.wav")
        try makeAudio(at: original)
        let before = try Data(contentsOf: original)
        let encodedAlias = URL(string: input.absoluteString + "..%2Finput%2FCanonical.wav")!
        let results = LocalAudioImporter(directory: output).importFiles([encodedAlias])
        if let song = results[0].fileURL {
            try expect(song.resolvingSymlinksInPath().deletingLastPathComponent() == output.resolvingSymlinksInPath(),
                       "an encoded path separator must never redirect a successful output outside the song folder")
        }
        let after = try Data(contentsOf: original)
        try expect(before == after, "rejecting or normalizing an encoded alias must preserve the original")
        print("PASS: encoded URL path aliases cannot escape the native song source")
    }
    try runLocalAudioLibraryChecks()
    try runLocalAudioArtworkChecks()
    print("PASS")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
