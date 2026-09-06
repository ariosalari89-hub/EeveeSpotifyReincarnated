import Foundation
import ImageIO
import CoreGraphics

func runLocalAudioArtworkServiceChecks() throws {
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Different filename.m4a")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "Tests/LocalAudioImport/Fixtures/embedded-art.m4a"), to: original)
        _ = LocalAudioImporter(directory: output).importFiles([original])
        let listed = try LocalAudioLibrary(directory: output).files()[0]
        let lookup = LocalAudioLibrary(directory: output).file(at: listed.fileURL)
        try expect(lookup == listed, "a native file lookup must reproduce the inventory snapshot; listed=\(listed), lookup=\(String(describing: lookup))")
        let service = LocalAudioArtworkService(directory: output)
        guard let url = service.imageURL(forTrackURI: "spotify:local:A%2FB+%2B+%E9%9F%B3:Windows%3A+Summer:Midnight+Library:0") else {
            throw TestFailure(description: "the player needs a native local-image request for a fully identified local track")
        }
        try expect(url.absoluteString.hasPrefix("spotify:localfileimage:") &&
                   url.absoluteString.components(separatedBy: ":").count == 3 &&
                   !url.absoluteString.contains("ipod-library"),
                   "a local artwork request must satisfy the observed native v1 image-factory route")
        let done = DispatchSemaphore(value: 0)
        var received: Data?
        let accepted = service.load(url, isCancelled: { false }) { data in received = data; done.signal() }
        try expect(accepted && done.wait(timeout: .now() + 5) == .success,
                   "an owned local-image request must complete asynchronously")
        guard let data = received,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TestFailure(description: "the native request must resolve actual embedded art by artist, album, title and duration, not filename")
        }
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let context = CGContext(data: &pixels, width: 32, height: 32, bitsPerComponent: 8,
                                bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        try expect(pixels[0] > 200 && pixels[2] < 70 && pixels[124] < 70 && pixels[126] > 200,
                   "the native local-track request must return its real red/blue embedded artwork")
        print("PASS: a fully encoded local track resolves embedded artwork asynchronously through the native image-URL seam")
    }
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Cover art.mp3")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "Tests/LocalAudioImport/Fixtures/embedded-art.mp3"), to: original)
        _ = LocalAudioImporter(directory: output).importFiles([original])
        let file = try LocalAudioLibrary(directory: output).files()[0]
        let encodedPath = file.fileURL.path.utf8.map { String(format: "%%%02X", $0) }.joined()
        let url = URL(string: "spotify:localfileimage:" + encodedPath)!
        let service = LocalAudioArtworkService(directory: output)
        let done = DispatchSemaphore(value: 0)
        var received: Data?
        let accepted = service.load(url, isCancelled: { false }) { received = $0; done.signal() }
        try expect(accepted && done.wait(timeout: .now() + 5) == .success && received != nil,
                   "native list requests for the actual imported path must use the same embedded-art recovery as the player")
        print("PASS: the native imported-file image URL recovers actual ID3 cover art")
    }
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Local.m4a")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "Tests/LocalAudioImport/Fixtures/embedded-art.m4a"), to: original)
        _ = LocalAudioImporter(directory: output).importFiles([original])
        let service = LocalAudioArtworkService(directory: output)
        let prefix = "spotify:local:A%2FB+%2B+%E9%9F%B3:"
        for uri in ["spotify:local:Wrong+artist:Windows%3A+Summer:Midnight+Library:0",
                    prefix + "Wrong+album:Midnight+Library:0",
                    prefix + "Windows%3A+Summer:Wrong+title:0",
                    prefix + "Windows%3A+Summer:Midnight+Library:20"] {
            let result = try serviceArtwork(service, service.imageURL(forTrackURI: uri)!)
            try expect(result == nil, "matching only some local-track fields must never borrow another file's artwork")
        }
        for uri in ["spotify:track:123", "spotify:episode:123", "spotify:local:bad", "spotify:local:%ZZ:::0", "spotify:local::::-1"] {
            try expect(service.imageURL(forTrackURI: uri) == nil,
                       "catalog tracks, podcasts and malformed local identities must not receive a synthesized local art request")
        }
        let nativeExternal = nativeArtworkURL(original)
        var callback = false
        let handled = service.load(nativeExternal, isCancelled: { false }) { _ in callback = true }
        try expect(!handled && !callback, "an external original's native image request must remain outside this adapter")
        let link = output.appendingPathComponent("Linked.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let linked = try serviceArtwork(service, nativeArtworkURL(link))
        try expect(linked == nil, "an imported-folder symlink must not disclose artwork from its external target")
        let cancellation = LocalAudioImportCancellation()
        cancellation.cancel()
        let cancelled = try serviceArtwork(service,
            service.imageURL(forTrackURI: prefix + "Windows%3A+Summer:Midnight+Library:0")!,
            isCancelled: { cancellation.isCancelled })
        try expect(cancelled == nil, "a cancelled artwork request must not return image bytes")
        print("PASS: full identity, imported scope and cancellation prevent unrelated or stale artwork")
    }
    try withDirectories { input, output in
        let sources = ["m4a", "mp3"].map { URL(fileURLWithPath: "Tests/LocalAudioImport/Fixtures/embedded-art." + $0) }
        _ = LocalAudioImporter(directory: output).importFiles(sources)
        let service = LocalAudioArtworkService(directory: output)
        let uri = "spotify:local:A%2FB+%2B+%E9%9F%B3:Windows%3A+Summer:Midnight+Library:0"
        let request = service.imageURL(forTrackURI: uri)!
        let ambiguous = try serviceArtwork(service, request)
        try expect(ambiguous == nil, "two files with the same full local identity must not choose an arbitrary cover")
        let library = LocalAudioLibrary(directory: output)
        try library.remove(library.files()[0])
        let selected = try library.files()[0]
        let originalPathRequest = nativeArtworkURL(selected.fileURL)
        let unique = try serviceArtwork(service, request)
        try expect(unique != nil, "removing an ambiguous duplicate must allow the one remaining file to resolve")
        let renamed = try library.rename(selected, toStem: "Filename changed only")
        let sameIdentity = try serviceArtwork(service, request)
        let oldPath = try serviceArtwork(service, originalPathRequest)
        try expect(sameIdentity != nil && oldPath == nil,
                   "a filename change must retain embedded-track artwork while the obsolete path stops returning data")
        try library.remove(renamed)
        let removed = try serviceArtwork(service, request)
        try expect(removed == nil, "a removed imported file must not survive as a stale artwork association")
        print("PASS: ambiguous identities, filename changes and removal resolve from the current imported copies")
    }
    try withDirectories { input, output in
        let manager = FileManager.default
        let source = URL(fileURLWithPath: "Tests/LocalAudioImport/Fixtures/embedded-art.m4a")
        try manager.createDirectory(at: output, withIntermediateDirectories: true)
        for index in 0..<200 {
            try manager.copyItem(at: source, to: output.appendingPathComponent("Song \(index).m4a"))
        }
        let service = LocalAudioArtworkService(directory: output)
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<12 {
            let cover = try serviceArtwork(service, nativeArtworkURL(output.appendingPathComponent("Song \(index).m4a")))
            try expect(cover != nil, "a visible imported-file row must resolve its embedded artwork in a larger collection")
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print(String(format: "MEASURE: 12 native path covers in a 200-song collection: %.3f seconds", elapsed))
        // A fixture-runtime latency budget for one visible list page, not a
        // physical-device frame-rate or universal performance claim.
        try expect(elapsed < 1, "twelve path-based covers must finish within one second in the 200-song native fixture")
    }
}

private func nativeArtworkURL(_ file: URL) -> URL {
    URL(string: "spotify:localfileimage:" + file.path.utf8.map { String(format: "%%%02X", $0) }.joined())!
}

private func serviceArtwork(_ service: LocalAudioArtworkService, _ url: URL,
                            isCancelled: @escaping () -> Bool = { false }) throws -> Data? {
    let done = DispatchSemaphore(value: 0)
    var data: Data?
    let accepted = service.load(url, isCancelled: isCancelled) { data = $0; done.signal() }
    try expect(accepted && done.wait(timeout: .now() + 5) == .success,
               "the owned artwork request did not produce a terminal result")
    return data
}
