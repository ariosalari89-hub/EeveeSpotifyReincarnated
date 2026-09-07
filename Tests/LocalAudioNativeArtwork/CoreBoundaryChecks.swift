import Foundation

func verifyCoreArtworkBoundaries(service: LocalAudioArtworkService, directory: URL, imageURL: URL) throws {
    let nativeBytes = Data([19, 81, 27, 64])
    let local = EeveeArtworkFixtureCoreRequest(imageURL, nativeBytes)
    EeveeArtworkFixtureLoad(local)
    try require(EeveeArtworkFixtureData(local) == nativeBytes && EeveeArtworkFixtureSuccesses(local) == 1 &&
                EeveeArtworkFixtureErrors(local) == 0,
                "a successful native local image must remain untouched, even when an embedded fallback exists")

    func drain() throws {
        let completed = DispatchSemaphore(value: 0)
        try require(service.load(imageURL, isCancelled: { false }) { _ in completed.signal() },
                    "the native v2 callback check requires an owned follow-up image")
        try require(completed.wait(timeout: .now() + 5) == .success, "the artwork queue must finish pending v2 requests")
    }
    for url in ["https://i.scdn.co/image/catalog-art", "spotify:image:episode-art",
                "spotify:localfileimage:ipod-library-existing", "spotify:localfileimage:malformed",
                "spotify:localfileimage:Wrong+artist:Windows%3A+Summer:Midnight+Library:0",
                "spotify:localfileimage:A%2FB+%2B+%E9%9F%B3:Wrong+album:Midnight+Library:0",
                "spotify:localfileimage:A%2FB+%2B+%E9%9F%B3:Windows%3A+Summer:Wrong+title:0",
                "spotify:localfileimage:A%2FB+%2B+%E9%9F%B3:Windows%3A+Summer:Midnight+Library:20"] {
        let failed = EeveeArtworkFixtureCoreRequest(URL(string: url)!, nil)
        EeveeArtworkFixtureLoad(failed)
        try drain()
        let error = EeveeArtworkFixtureError(failed).map { $0 as NSError }
        try require(EeveeArtworkFixtureSuccesses(failed) == 0 && EeveeArtworkFixtureErrors(failed) == 1 &&
                    error?.domain == "NativeImageFixture" && error?.code == 404,
                    "unowned or unavailable core artwork must preserve its original native error, never borrow a cover")
    }
    print("PASS: native v2 successes remain native; catalog, iPod, malformed and unmatched errors are preserved")

    let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: directory.appendingPathComponent("embedded-art.m4a"),
                                                         options: [], error: &error) { _ in
            held.signal()
            _ = release.wait(timeout: .now() + 10)
        }
    }
    try require(held.wait(timeout: .now() + 5) == .success, "the external writer must hold the v2 fixture before reuse")
    defer { release.signal() }
    let reused = EeveeArtworkFixtureCoreRequest(imageURL, nil)
    let stale = EeveeArtworkFixtureCoreRequest(imageURL, nil)
    let stopped = EeveeArtworkFixtureCoreRequest(imageURL, nil)
    EeveeArtworkFixtureLoad(reused)
    EeveeArtworkFixtureLoad(reused)
    EeveeArtworkFixtureLoad(stale)
    EeveeArtworkFixtureSetURL(stale, URL(string: "spotify:localfileimage:Different:Next:Song:20")!)
    EeveeArtworkFixtureLoad(stopped)
    EeveeArtworkFixtureCancel(stopped)
    release.signal()
    try drain()
    try require(EeveeArtworkFixtureData(reused) != nil && EeveeArtworkFixtureSuccesses(reused) == 1 &&
                EeveeArtworkFixtureErrors(reused) == 0 &&
                EeveeArtworkFixtureSuccesses(stale) == 0 && EeveeArtworkFixtureErrors(stale) == 0 &&
                EeveeArtworkFixtureSuccesses(stopped) == 0 && EeveeArtworkFixtureErrors(stopped) == 0,
                "only the current uncancelled core request may deliver a recovered image")
    print("PASS: native v2 recovery respects cancellation, changed songs and reused-request generations")
}
