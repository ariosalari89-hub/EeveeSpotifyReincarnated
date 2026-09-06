import Foundation

func verifyNativeArtworkBoundaries(service: LocalAudioArtworkService, directory: URL, imageURL: URL, uri: String) throws {
    let known = "https://i.scdn.co/image/native-existing"
    for nonlocal in ["spotify:track:catalog-track", "spotify:episode:spoken-audio"] {
        let values: [String: Any] = ["title": "Unchanged", "image_url": known]
        let track = EeveeArtworkFixtureTrack(nonlocal, values)
        try require(NSDictionary(dictionary: EeveeArtworkFixtureMetadata(track)).isEqual(to: values),
                    "catalog and episode metadata must remain unchanged")
    }
    let existing = EeveeArtworkFixtureTrack(uri, ["image_url": known, "thumbnail_image_url": "spotify:localfileimage:ipod-library-existing"])
    let retained = EeveeArtworkFixtureMetadata(existing)
    try require(retained["image_url"] as? String == known &&
                retained["thumbnail_image_url"] as? String == "spotify:localfileimage:ipod-library-existing",
                "local tracks with existing native artwork must retain those routes")

    let unowned = EeveeArtworkFixtureRequest(URL(string: "spotify:localfileimage:ipod-library-existing")!)
    EeveeArtworkFixtureLoad(unowned)
    try require(EeveeArtworkFixtureOriginalLoads(unowned) == 1 && EeveeArtworkFixtureSuccesses(unowned) == 0,
                "unowned native image routes must still use the original loader")

    func drain() throws {
        let completed = DispatchSemaphore(value: 0)
        try require(service.load(imageURL, isCancelled: { false }) { _ in completed.signal() },
                    "the native callback check requires an owned follow-up image")
        try require(completed.wait(timeout: .now() + 5) == .success, "the artwork queue must finish its pending requests")
    }
    let absent = EeveeArtworkFixtureRequest(service.imageURL(forTrackURI: "spotify:local:Nobody:Missing:Not+imported:0")!)
    EeveeArtworkFixtureLoad(absent)
    let cancelled = EeveeArtworkFixtureRequest(imageURL)
    EeveeArtworkFixtureCancel(cancelled)
    EeveeArtworkFixtureLoad(cancelled)
    try drain()
    try require(EeveeArtworkFixtureErrors(absent) == 1 && EeveeArtworkFixtureSuccesses(absent) == 0 &&
                EeveeArtworkFixtureOriginalLoads(absent) == 0,
                "missing embedded art must produce a single native absence without borrowing or starting a legacy load")
    try require(EeveeArtworkFixtureErrors(cancelled) == 0 && EeveeArtworkFixtureSuccesses(cancelled) == 0 &&
                EeveeArtworkFixtureOriginalLoads(cancelled) == 0,
                "a cancelled owned request must not deliver an image or error")

    // A real external coordinated writer holds the selected file while a
    // native request is reused. The production service and callbacks stay real.
    let held = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: directory.appendingPathComponent("embedded-art.m4a"),
                                                         options: [], error: &error) { _ in
            held.signal()
            _ = release.wait(timeout: .now() + 10)
        }
    }
    try require(held.wait(timeout: .now() + 5) == .success, "the system writer must acquire the fixture before request reuse")
    defer { release.signal() }
    let stale = EeveeArtworkFixtureRequest(imageURL)
    let repeated = EeveeArtworkFixtureRequest(imageURL)
    let stopped = EeveeArtworkFixtureRequest(imageURL)
    EeveeArtworkFixtureLoad(stale)
    EeveeArtworkFixtureSetURL(stale, URL(string: "spotify:localfileimage:ipod-library-reused")!)
    EeveeArtworkFixtureLoad(repeated)
    EeveeArtworkFixtureLoad(repeated)
    EeveeArtworkFixtureLoad(stopped)
    EeveeArtworkFixtureCancel(stopped)
    release.signal()
    try drain()
    try require(EeveeArtworkFixtureSuccesses(stale) == 0 && EeveeArtworkFixtureErrors(stale) == 0 &&
                EeveeArtworkFixtureSuccesses(stopped) == 0 && EeveeArtworkFixtureErrors(stopped) == 0,
                "a pending request must not repaint after its URL changes or it is cancelled")
    try require(EeveeArtworkFixtureSuccesses(repeated) == 1 && EeveeArtworkFixtureErrors(repeated) == 0,
                "only the latest generation of a reused native request may deliver its cover")
    print("PASS: native catalog/existing art fallthrough, absent art, cancellation and reused-request lifetime")
}
