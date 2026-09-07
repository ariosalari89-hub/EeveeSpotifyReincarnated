import Foundation
import ImageIO
import EeveeSpotifyC

struct Failure: Error, CustomStringConvertible { let description: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure(description: message) }
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-local-art-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
do {
    let contractData = try Data(contentsOf: URL(fileURLWithPath: "Tests/LocalAudioNativeArtwork/Spotify9176Contract.json"))
    let contract = try JSONSerialization.jsonObject(with: contractData) as! [String: Any]
    for (className, selectors) in contract["classes"] as! [String: [String: String]] {
        for (selector, encoding) in selectors {
            try require(EeveeArtworkFixtureEncoding(className, selector) == encoding,
                        "native fixture must match the independently extracted Spotify ABI: \(className).\(selector)")
        }
    }
    let source = URL(fileURLWithPath: "Tests/LocalAudioImport/Fixtures/embedded-art.m4a")
    let imports = LocalAudioImporter(directory: directory).importFiles([source])
    try require(imports.first?.fileURL != nil, "native artwork scenario requires a real imported audio copy")
    let diagnostics = LocalAudioArtworkDiagnostics(fileURL: directory.appendingPathComponent(".artwork-active.log"))
    let record = diagnostics.record
    let service = LocalAudioArtworkService(directory: directory, diagnostic: record)
    let installed = EeveeLocalAudioInstallArtworkWithDiagnostics({ uri in service.imageURL(forTrackURI: uri)?.absoluteString },
                                      { url, cancelled, completion in service.load(url, isCancelled: cancelled, completion: completion) }, record)
    try require(installed, "the local artwork adapter must install against the real Spotify 9.1.76 method signatures")
    let uri = "spotify:local:A%2FB+%2B+%E9%9F%B3:Windows%3A+Summer:Midnight+Library:0"
    let original: [String: Any] = ["title": "Midnight Library", "artist_name": "A/B + 音"]
    let track = EeveeArtworkFixtureTrack(uri, original)
    guard let imageURL = EeveeArtworkFixtureImageURL(track) else {
        throw Failure(description: "the native local player getter must receive an image URL when its metadata lacks cover URLs")
    }
    let metadata = EeveeArtworkFixtureMetadata(track)
    try require(["image_url", "thumbnail_image_url", "image_large_url", "image_xlarge_url"].allSatisfy {
        metadata[$0] as? String == imageURL.absoluteString
    } && metadata["title"] as? String == "Midnight Library" && original["image_url"] == nil,
                "native artwork sizes must share a local request without mutating title tags or the source metadata dictionary")
    let request = EeveeArtworkFixtureRequest(imageURL)
    EeveeArtworkFixtureLoad(request)
    let deadline = Date().addingTimeInterval(5)
    while EeveeArtworkFixtureData(request) == nil && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    guard let data = EeveeArtworkFixtureData(request), let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw Failure(description: "the native local-image request must deliver embedded cover data through its native success callback")
    }
    try require(image.width == 32 && image.height == 32 && EeveeArtworkFixtureSuccesses(request) == 1 &&
                EeveeArtworkFixtureErrors(request) == 0 && EeveeArtworkFixtureOriginalLoads(request) == 0,
                "an owned native request must deliver one actual cover without also starting the failing legacy load")
    print("PASS: real imported artwork flows through the guarded native player getter, image request and native callback")
    // The native core's format string is spotify:localfileimage:%s%c%s%c%s%c%d.
    // Unlike the legacy file-path route, the player can already supply this URL.
    let playerImageURL = URL(string: "spotify:localfileimage:A%2FB+%2B+%E9%9F%B3:Windows%3A+Summer:Midnight+Library:0")!
    let core = EeveeArtworkFixtureCoreRequest(playerImageURL, nil)
    EeveeArtworkFixtureLoad(core)
    let coreDeadline = Date().addingTimeInterval(5)
    while EeveeArtworkFixtureData(core) == nil && Date() < coreDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    try require(EeveeArtworkFixtureData(core) == data && EeveeArtworkFixtureSuccesses(core) == 1 &&
                EeveeArtworkFixtureErrors(core) == 0 && EeveeArtworkFixtureOriginalLoads(core) == 1,
                "a failed native v2 player-art request must recover the imported cover through the native success callback")
    print("PASS: an existing native v2 player-art URL recovers embedded cover data after native loading fails")
    try verifyCoreArtworkBoundaries(service: service, directory: directory, imageURL: playerImageURL)
    try verifyNativeArtworkBoundaries(service: service, directory: directory, imageURL: imageURL, uri: uri)
    try verifyArtworkDiagnostics(imageURL: playerImageURL, data: data, trace: {
        guard let snapshot = diagnostics.exportSnapshot() else {
            throw Failure(description: "native pipeline observations must reach the actual artwork export")
        }
        let data = try Data(contentsOf: snapshot)
        if let destination = ProcessInfo.processInfo.environment["ARTWORK_DIAGNOSTIC_SAMPLE"] {
            try data.write(to: URL(fileURLWithPath: destination), options: .withoutOverwriting)
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2)
            return parts.count == 3 && parts[0] == "[LocalArtwork]" && parts[1].hasPrefix("ms=") ? String(parts[2]) : nil
        }
    })
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
