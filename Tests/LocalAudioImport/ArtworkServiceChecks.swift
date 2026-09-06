import Foundation
import ImageIO
import CoreGraphics

func runLocalAudioArtworkServiceChecks() throws {
    try withDirectories { input, output in
        let original = input.appendingPathComponent("Different filename.m4a")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "Tests/LocalAudioImport/Fixtures/embedded-art.m4a"), to: original)
        _ = LocalAudioImporter(directory: output).importFiles([original])
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
}
