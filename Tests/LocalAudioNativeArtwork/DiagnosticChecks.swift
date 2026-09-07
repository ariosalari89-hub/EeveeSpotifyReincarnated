import Foundation

func verifyArtworkDiagnostics(imageURL: URL, data: Data, trace: () throws -> [String]) throws {
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
    let selected = EeveeArtworkFixtureTrack("spotify:local:PrivateCanary:PrivateCanary:PrivateCanary:0", [
        "image_url": imageURL.absoluteString,
        "image_large_url": imageURL.absoluteString,
        "image_xlarge_url": imageURL.absoluteString
    ])
    for size in 0...2 {
        try require(EeveeArtworkFixtureCoverURL(selected, size) == imageURL,
                    "the native cover-URL getter must retain the selected URL at every artwork size")
    }
    try require(EeveeArtworkFixtureConsumerForwarding(imageURL, NSObject(), error) &&
                EeveeArtworkFixtureConsumerForwarding(catalogURL, NSObject(), error),
                "the actual image consumer must receive every original local/catalog success, nil image, time, context and error")
    try require(EeveeArtworkFixtureViewStates(imageURL, error),
                "observing cover and mini-player views must preserve original getters, layouts, image, visibility, size and reuse behavior")
    let events = try trace()
    func field(_ name: String, in event: String) -> String? {
        event.split(separator: " ").first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }
    guard let binding = events.first(where: { $0.hasPrefix("native binding kind=standard ") && field("route", in: $0) == "local" }),
          let identity = field("image", in: binding), identity != "0" else {
        throw Failure(description: "the selected native cover URL needs an anonymous identity in the actual exported trace")
    }
    for kind in ["large", "xlarge"] {
        try require(events.contains(where: { $0.hasPrefix("native binding kind=\(kind) ") && field("image", in: $0) == identity }),
                    "the same selected URL must retain its trace identity across native cover sizes")
    }
    for stage in ["request", "remote-image", "consumer-image", "consumer-error"] {
        try require(events.contains(where: { $0.hasPrefix("native display stage=\(stage) ") && field("image", in: $0) == identity }),
                    "the exported trace must connect the selected local cover to its native \(stage) boundary")
    }
    for surface in ["cover", "legacy-cover"] {
        let snapshots = events.filter { $0.hasPrefix("native view surface=\(surface) ") }
        for flags in ["mounted=1 hidden=0 sized=1 images=1 filled=0 visible=0 linked=0",
                      "mounted=1 hidden=0 sized=1 images=1 filled=1 visible=1 linked=1",
                      "mounted=1 hidden=1 sized=1 images=1 filled=1 visible=0 linked=1",
                      "mounted=1 hidden=0 sized=1 images=1 filled=1 visible=0 linked=1"] {
            try require(snapshots.contains(where: { $0.hasSuffix(flags) }),
                        "the \(surface) trace must distinguish the native empty, visible, hidden and zero-sized image states: \(flags)")
        }
        try require(!snapshots.contains(where: { field("sized", in: $0) == "0" }),
                    "a reused cover view must stop reporting changes under its old owner")
    }
    try require(events.contains(where: { $0.hasPrefix("native view surface=bar ") && $0.hasSuffix("filled=1 visible=1 linked=1") }) &&
                events.contains(where: { $0.hasPrefix("native view-image surface=cover ") && field("image", in: $0) == identity }),
                "view observations must include the mini-player and connect a loaded image object to the native cover")
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
    print("PASS: selected cover URLs and native consumer callbacks share anonymous trace identities without altering native effects or leaking identifiers")
}
