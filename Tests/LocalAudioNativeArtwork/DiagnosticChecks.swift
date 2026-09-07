import Foundation

func verifyArtworkDiagnostics(imageURL: URL, data: Data, trace: () -> [String]) throws {
    let request = EeveeArtworkFixtureCoreRequest(imageURL, data)
    let error = NSError(domain: "PrivateCanary-domain", code: 71, userInfo: [
        NSLocalizedDescriptionKey: "PrivateCanary-description",
        NSURLErrorFailingURLStringErrorKey: "https://example.invalid/PrivateCanary-token"
    ])
    try require(EeveeArtworkFixtureRemoteForwarding(imageURL, request, data, error),
                "diagnostic image observers must forward every native argument, original result and error unchanged")
    let catalogURL = URL(string: "https://example.invalid/PrivateCanary-art?token=PrivateCanary")!
    let catalog = EeveeArtworkFixtureCoreRequest(catalogURL, data)
    try require(EeveeArtworkFixtureRemoteForwarding(catalogURL, catalog, data, error),
                "catalog image requests must retain their native arguments and results with diagnostics installed")
    let local = EeveeArtworkFixtureTrack("spotify:local:PrivateCanary:PrivateCanary:PrivateCanary:0", [
        "title": "PrivateCanary-title", "image_url": "https://example.invalid/PrivateCanary-art"
    ])
    try require(EeveeArtworkFixtureMetadata(local)["title"] as? String == "PrivateCanary-title",
                "diagnostic metadata inspection must retain native display fields")
    let events = trace()
    for expected in ["native install metadata=1 legacy=1 core=1 remote=1",
                     "native legacy load route=local-owned",
                     "native core load route=local-v2",
                     "native core fallback owned=1",
                     "native remote request route=local-v2",
                     "native remote load class=SPTCoreImageLoaderRequest route=local-v2",
                     "native remote complete=image route=local-v2 present=1",
                     "native remote complete=image route=local-v2 present=0",
                     "native remote complete=error route=local-v2 code=71"] {
        try require(events.contains(expected), "native artwork diagnostics must expose the observed stage: \(expected)")
    }
    try require(events.contains(where: { $0.hasPrefix("native metadata uri=local ") }) &&
                events.contains(where: { $0.hasPrefix("native core result=success route=local-v2 bytes=") }) &&
                events.contains(where: { $0.hasPrefix("native remote bytes route=local-v2 bytes=") }),
                "metadata inspection and native image-data results must be independently observable")
    try require(!events.joined().contains("PrivateCanary") && !events.joined().contains("Midnight") &&
                !events.joined().contains("Windows") && !events.joined().contains("https://"),
                "native diagnostic output must exclude title fields, raw URLs, errors, context and cache keys")
    print("PASS: native image diagnostics expose guarded hook, metadata, loader and callback stages without altering native effects or leaking identifiers")
}
