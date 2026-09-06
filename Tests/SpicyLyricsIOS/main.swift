import UIKit
import WebKit

// Every runtime hook observes the same changing preference, as UserDefaults
// does in Spotify; separate fixtures must not install conflicting closures.
private enum QALyricsPreference { static var enabled = true }

@objc(SPTPlayerTrack) final class QALyricsAvailabilityTrack: NSObject {
    let original: NSDictionary = ["has_lyrics": "false", "title": "Availability fixture", "artist_name": "Unchanged artist"]
    let uri: NSURL
    init(_ uri: String) { self.uri = NSURL(string: uri)! }
    @objc dynamic func metadata() -> NSDictionary { original }
    @objc dynamic func URI() -> NSURL { uri }
}

@objc(_TtC22Lyrics_CardElementImpl15CardContentView)
final class QACardContentView: UIView {}
@objc(_TtC17Canvas_CommonImpl26CanvasNowPlayingLyricsView)
final class QAInlineLyricsView: UIView {}
@objc(_TtC17Canvas_CommonImpl33CanvasNowPlayingLyricsElementView)
final class QAMigratedCanvasLyricsView: UIView {}
@objc(_TtC22Lyrics_NPVContainerKit19LyricsContainerView)
final class QAStillLyricsView: UIView {}
@objc(_TtC28NowPlaying_ContentLayersImpl25LegacyLyricsContainerView)
final class QALegacyLyricsView: UIView {}
@objc(_TtC22Lyrics_CardElementImpl14CardHeaderView)
final class QACardHeaderView: UIView {
    lazy var expandButtonContainerView: UIView = UIView()
}
@objc(_TtC22Lyrics_CardElementImpl8CardView)
final class QACardView: UIView {
    let headerView: UIView
    let contentView: UIView
    let stackView = UIView()
    let gradientLayer = CAGradientLayer()
    init(frame: CGRect, header: UIView, content: UIView) {
        headerView = header
        contentView = content
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.34, green: 0.49, blue: 0.62, alpha: 1)
        gradientLayer.colors = [backgroundColor!.cgColor, backgroundColor!.cgColor]
        layer.insertSublayer(gradientLayer, at: 0)
        layer.cornerRadius = 18
        clipsToBounds = true
        stackView.clipsToBounds = true
        content.clipsToBounds = true
        stackView.addSubview(header)
        stackView.addSubview(content)
        addSubview(stackView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
        stackView.frame = bounds.insetBy(dx: 16, dy: 16)
        headerView.frame = CGRect(x: 0, y: 0, width: stackView.bounds.width, height: 40)
        contentView.frame = CGRect(x: 0, y: 40, width: stackView.bounds.width, height: stackView.bounds.height - 40)
    }
}

// Only Spotify and its network service are simulated. The full-screen owner,
// WebKit host, renderer and UIKit lifecycle below are the shipping sources.
private enum QADiagnostics {
    static let lock = NSLock()
    static var messages = [String]()
    static func append(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append("\(Date().timeIntervalSince1970) \(message)")
        if messages.count > 180 { messages.removeFirst() }
    }
    static func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return messages.joined(separator: "\n")
    }
}
func writeDebugLog(_ message: String) { QADiagnostics.append(message); print(message) }

final class BundleHelper {
    static let shared = BundleHelper()
    func resourceURL(_ name: String, withExtension ext: String, subdirectory: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
    }
}

extension Notification.Name {
    static let spicyLyricsPlaybackStateDidChange = Notification.Name("SpicyQA.State")
}

final class SpicyLyricsPlaybackBridge {
    static let shared = SpicyLyricsPlaybackBridge()
    var generation = 1
    var sequence = 0
    var paused = false
    var position = 19_000
    var shuffle = 0
    var repeatMode = 0
    var onSkip: (() -> Void)?
    var payloadReads = 0
    var artwork = ""
    var trackIDOverride: String?

    func sessionPayload() -> [String: Any]? {
        payloadReads += 1
        sequence += 1
        return [
            "generation": String(generation), "sequence": String(sequence),
            "trackId": trackIDOverride ?? "track-\(generation)", "positionMs": position, "durationMs": 180_000,
            "isPlaying": !paused, "isPaused": paused, "isAdvancing": false,
            "playbackRate": 1, "requiresFreshObservation": false,
            "shuffleEnabled": shuffle != 0, "shuffleMode": ["off", "shuffle", "smart"][shuffle],
            "smartShuffleAvailable": true, "repeatMode": ["off", "context", "track"][repeatMode],
            "track": ["id": trackIDOverride ?? "track-\(generation)", "title": "Track \(generation)", "artist": "Lyric layout sample", "artwork": artwork]
        ]
    }

    func perform(command: String, value: Double? = nil) -> Bool {
        switch command {
        case "play": paused = false
        case "pause": paused = true
        case "togglePlay": paused.toggle()
        case "next", "previous":
            generation += 1
            position = 19_000
            onSkip?()
        case "toggleShuffle": shuffle = (shuffle + 1) % 3
        case "cycleRepeat": repeatMode = (repeatMode + 1) % 3
        case "seek": position = Int((value ?? 0) * 1000)
        default: return false
        }
        NotificationCenter.default.post(name: .spicyLyricsPlaybackStateDidChange, object: nil)
        return true
    }
    func suspendPlaybackClock() {}
    func resumeAwaitingObservation() {}
}

final class SpicyLyricsRepository {
    static let shared = SpicyLyricsRepository()
    func rendererPayloadData(for trackID: String, forceRefresh: Bool, shouldContinue: () -> Bool) throws -> Data {
        let tokens: [[String: Any]] = (0..<14).map { index in
            ["Text": "Day-", "StartTime": Double(index), "EndTime": Double(index + 1), "IsPartOfWord": true]
        }
        let payload: [String: Any] = ["Type": "Syllable", "Content": [
            ["Type": "Vocal", "OppositeAligned": true,
             "Lead": ["StartTime": 0, "EndTime": 14, "Syllables": tokens]],
            ["Type": "Vocal", "Lead": ["StartTime": 15, "EndTime": 30, "Syllables": [
                ["Text": trackID + " ", "StartTime": 15, "EndTime": 20],
                ["Text": "A long lyric should stay inside this phone screen", "StartTime": 20, "EndTime": 30]
            ]]]
        ]]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

struct QAFailure: Error { let message: String }

@MainActor final class QARunner {
    let source: UIViewController
    let scene: UIWindowScene
    var checks: [String] = []
    var rendererFailures: [String] = []
    init(source: UIViewController, scene: UIWindowScene) { self.source = source; self.scene = scene }

    // Persist phase boundaries independently of final completion. A stalled
    // simulator or recording service must not hide already-executed checks.
    func checkpoint(_ phase: String) {
        let heading = "QA phase: \(phase) at \(ISO8601DateFormatter().string(from: Date()))"
        let report = ([heading] + checks).joined(separator: "\n")
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qa-progress.txt")
        try? report.write(to: path, atomically: true, encoding: .utf8)
    }

    func testNativeAvailability() async throws {
        let trackID = "3N1zlgIGnFcnNiTuDaeYzy"
        let track = QALyricsAvailabilityTrack("spotify:track:" + trackID)
        QALyricsPreference.enabled = true
        SpicyLyricsEmbeddedSurfaces.install { QALyricsPreference.enabled }
        SpicyLyricsPlaybackBridge.shared.trackIDOverride = trackID
        let caption = QAInlineLyricsView(frame: CGRect(x: 24, y: 140, width: 320, height: 52))
        let nativeAvailable = (track.metadata()["has_lyrics"] as? String) == "true"
        // Native metadata enables the caption, but the independent server feed
        // must contain a Lyrics section before a preview is even instantiated.
        // Do not precreate a card: that hid the user's missing-card regression.
        let feedURL = URL(string: "https://spclient.wg.spotify.com/scrollsita/v1/scroll/spotify:track:" + trackID)!
        let originalFeed = NativeScrollFeedFixture.withoutLyrics
        guard try NativeScrollFeedFixture.cards(in: originalFeed).map(\.kind) == [3, 4] else {
            throw QAFailure(message: "external feed fixture must start with Explore/Credits and no Lyrics card")
        }
        let deliveredFeed = SpicyLyricsNativePreview.restoringMissingCard(
            in: originalFeed, for: feedURL, enabled: QALyricsPreference.enabled
        ) ?? originalFeed
        let nativeCards = try NativeScrollFeedFixture.cards(in: deliveredFeed)
        guard nativeCards.map(\.kind) == [5, 3, 4],
              nativeCards.first?.entityURI == "spotify:track:" + trackID else {
            throw QAFailure(message: "native feed omits the preview despite working caption availability: has_lyrics=\(nativeAvailable), cards=\(nativeCards.map(\.kind))")
        }
        let card = QACardContentView(frame: CGRect(x: 16, y: 200, width: 340, height: 320))
        card.isHidden = !nativeAvailable
        caption.isHidden = !nativeAvailable
        source.view.addSubview(card); source.view.addSubview(caption)
        defer {
            card.removeFromSuperview(); caption.removeFromSuperview()
            SpicyLyricsPlaybackBridge.shared.trackIDOverride = nil
            QALyricsPreference.enabled = false
        }
        func findWeb(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap(findWeb).first
        }
        var loaded = false
        // The shipping host allows its initial six-second startup plus two
        // six-second recoveries. An eight-second polling allowance could fail
        // while that public recovery lifecycle was still legitimately running.
        // Keep production timeouts/retry limits intact and require real current
        // views to paint within their complete 18.24-second recovery window.
        let startedAt = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - startedAt < 20 {
            let script = "document.querySelector('#lyrics')?.textContent.includes('\(trackID)') === true"
            if let cardWeb = findWeb(card), let captionWeb = findWeb(caption),
               (try? await cardWeb.evaluateJavaScript(script)) as? Bool == true,
               (try? await captionWeb.evaluateJavaScript(script)) as? Bool == true,
               cardWeb.alpha > 0.99, captionWeb.alpha > 0.99,
               cardWeb.window != nil, captionWeb.window != nil {
                loaded = true; break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let screenshot = UIGraphicsImageRenderer(bounds: source.view.bounds).image { _ in
            source.view.drawHierarchy(in: source.view.bounds, afterScreenUpdates: true)
        }
        try screenshot.pngData()?.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qa-availability.png"))
        guard nativeAvailable, loaded, !card.isHidden, !caption.isHidden else {
            throw QAFailure(message: "native preview/caption did not paint within the shipping startup/recovery window: nativeAvailable=\(nativeAvailable), loaded=\(loaded), elapsed=\(ProcessInfo.processInfo.systemUptime - startedAt)")
        }
        checks.append("availability fixture painted current native card and caption after \(ProcessInfo.processInfo.systemUptime - startedAt) seconds; shipping startup/recovery limits unchanged")
        try await captureSimulatorScreen(marker: "availability", label: "lyrics availability")
        guard track.original["has_lyrics"] as? String == "false",
              track.metadata()["title"] as? String == "Availability fixture",
              track.metadata()["artist_name"] as? String == "Unchanged artist",
              QALyricsAvailabilityTrack("spotify:episode:3N1zlgIGnFcnNiTuDaeYzy").metadata()["has_lyrics"] as? String == "false",
              QALyricsAvailabilityTrack("spotify:local:artist:album:song:123").metadata()["has_lyrics"] as? String == "false" else {
            throw QAFailure(message: "lyrics availability changed stored metadata or a non-music URI")
        }
        QALyricsPreference.enabled = false
        guard track.metadata()["has_lyrics"] as? String == "false" else {
            throw QAFailure(message: "disabled Spicy Lyrics still overrides native availability")
        }
        checks.append("native feed without Lyrics gains one preview before preserved Explore/Credits; has_lyrics=false music track paints card and caption; original metadata, podcasts, local tracks and disabled behavior are preserved")
    }

    func webView() -> WKWebView? {
        for window in scene.windows where !window.isHidden {
            if let web = window.rootViewController?.view.subviews.compactMap({ $0 as? WKWebView }).first { return web }
        }
        return nil
    }
    func evaluate(_ js: String) async throws -> Any? {
        guard let web = webView() else { throw QAFailure(message: "renderer window disappeared") }
        return try await web.evaluateJavaScript(js)
    }
    func waitFor(_ label: String, _ js: String) async throws {
        for _ in 0..<100 {
            if webView() != nil,
               (try await evaluate("Boolean(document.querySelector('#app') && window.SpicyNative)")) as? Bool == true,
               (try await evaluate(js)) as? Bool == true { checks.append(label); return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw QAFailure(message: label)
    }
    func snapshot(_ name: String) async throws {
        guard let web = webView() else { throw QAFailure(message: "snapshot has no renderer") }
        let image = try await web.takeSnapshot(configuration: nil)
        guard let png = image.pngData() else { throw QAFailure(message: "snapshot encoding failed") }
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name + ".png")
        try png.write(to: path)
    }

    func waitForSettledLandscape() async throws {
        var stableSamples = 0
        for _ in 0..<100 {
            if let window = scene.keyWindow, let web = webView(),
               window.rootViewController?.transitionCoordinator == nil,
               scene.interfaceOrientation.isLandscape,
               web.transform == .identity,
               abs(web.bounds.width - window.bounds.width) < 1,
               abs(web.bounds.height - window.bounds.height) < 1,
               let metrics = try await evaluate("[innerWidth,innerHeight,visualViewport.width,visualViewport.height]") as? [NSNumber],
               metrics.count == 4,
               abs(metrics[0].doubleValue - Double(web.bounds.width)) < 1,
               abs(metrics[1].doubleValue - Double(web.bounds.height)) < 1,
               abs(metrics[2].doubleValue - metrics[0].doubleValue) < 1,
               abs(metrics[3].doubleValue - metrics[1].doubleValue) < 1 {
                stableSamples += 1
                if stableSamples >= 5 {
                    checks.append("settled landscape native and visual viewport agree: \(metrics)")
                    return
                }
            } else { stableSamples = 0 }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw QAFailure(message: "landscape native/visual viewport did not settle")
    }

    func captureSimulatorScreen(marker: String = "screen", label: String = "landscape") async throws {
        // UIKit's hierarchy snapshot can omit composited WebKit controls.
        // Ask the outer harness for a screenshot of the real simulator display.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try label.write(to: documents.appendingPathComponent("qa-\(marker)-ready.txt"),
                              atomically: true, encoding: .utf8)
        // This deadline belongs to the external simctl screenshot process, not
        // the app's response time. On a cold CI host capture alone took 14.3s,
        // exhausting the former 15s allowance before the shell could acknowledge.
        // Keep every app/viewport deadline unchanged and still require the actual
        // completed display capture before advancing to another screen.
        let captureDeadline = ProcessInfo.processInfo.systemUptime + 60
        while ProcessInfo.processInfo.systemUptime < captureDeadline {
            if FileManager.default.fileExists(atPath: documents.appendingPathComponent("qa-\(marker)-done.txt").path) {
                checks.append("actual simulator \(label) display captured by simctl")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw QAFailure(message: "outer simulator display capture did not acknowledge")
    }

    func failureDiagnostics() async -> String {
        var details = ["scene activation=\(scene.activationState.rawValue) generation=\(SpicyLyricsPlaybackBridge.shared.generation)"]
        for window in scene.windows {
            details.append("window key=\(window.isKeyWindow) hidden=\(window.isHidden) frame=\(window.frame) root=\(String(describing: window.rootViewController))")
            for web in window.rootViewController?.view.subviews.compactMap({ $0 as? WKWebView }) ?? [] {
                let content = try? await web.evaluateJavaScript("JSON.stringify({ready:!!window.SpicyNative,state:document.readyState,text:document.querySelector('#lyrics')?.textContent,busy:document.querySelector('#app')?.getAttribute('aria-busy'),width:innerWidth,height:innerHeight})")
                details.append("web loading=\(web.isLoading) alpha=\(web.alpha) frame=\(web.frame) url=\(String(describing: web.url)) content=\(String(describing: content))")
            }
        }
        details.append(QADiagnostics.snapshot())
        return details.joined(separator: "\n")
    }

    func testEmbeddedSurfaces() async throws {
        guard let root = scene.keyWindow?.rootViewController else { throw QAFailure(message: "missing native player root") }
        let restartMarker = "[SpicyRenderer] recreating WebKit"
        let restartsBeforeSetup = QADiagnostics.snapshot().components(separatedBy: restartMarker).count
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await Task.sleep(nanoseconds: 600_000_000)
        QALyricsPreference.enabled = true
        let artworkImage = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor(red: 0.2, green: 0.38, blue: 0.6, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            UIColor(red: 0.72, green: 0.38, blue: 0.2, alpha: 1).setFill()
            context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        }
        let previousArtwork = SpicyLyricsPlaybackBridge.shared.artwork
        SpicyLyricsPlaybackBridge.shared.artwork = "data:image/png;base64," + (artworkImage.pngData()?.base64EncodedString() ?? "")
        defer { SpicyLyricsPlaybackBridge.shared.artwork = previousArtwork }
        SpicyLyricsEmbeddedSurfaces.install { QALyricsPreference.enabled }
        let width = min(360, root.view.bounds.width - 32)
        let card = QACardContentView(frame: CGRect(x: 0, y: 40, width: width - 32, height: 320))
        card.backgroundColor = UIColor(red: 0.50, green: 0.38, blue: 0.56, alpha: 1)
        let original = UILabel(frame: card.bounds)
        original.text = "ORIGINAL NATIVE LYRICS MUST NOT FLASH"
        card.addSubview(original)
        let originalTap = UITapGestureRecognizer()
        card.addGestureRecognizer(originalTap)
        let header = QACardHeaderView(frame: CGRect(x: 0, y: 0, width: width - 32, height: 40))
        let heading = UILabel(frame: CGRect(x: 8, y: 0, width: 220, height: 40))
        heading.text = "Lyrics · native share"
        heading.textColor = .white
        header.addSubview(heading)
        header.expandButtonContainerView.frame = CGRect(x: width - 32 - 44, y: 0, width: 44, height: 40)
        header.expandButtonContainerView.autoresizingMask = [.flexibleLeftMargin]
        let nativeExpand = UIButton(type: .system)
        nativeExpand.frame = header.expandButtonContainerView.bounds
        nativeExpand.setTitle("↗", for: .normal)
        var nativeExpandCount = 0
        nativeExpand.addAction(UIAction { _ in nativeExpandCount += 1 }, for: .touchUpInside)
        header.expandButtonContainerView.addSubview(nativeExpand)
        header.addSubview(header.expandButtonContainerView)
        let cardShell = QACardView(frame: CGRect(x: 16, y: 180, width: width, height: 392), header: header, content: card)
        root.view.addSubview(cardShell)
        cardShell.setNeedsLayout(); cardShell.layoutIfNeeded()
        let inline = QAInlineLyricsView(frame: CGRect(x: 24, y: 120, width: width - 16, height: 52))
        let originalInline = UILabel(frame: inline.bounds)
        originalInline.text = "OLD CAPTION"
        inline.addSubview(originalInline)
        root.view.addSubview(inline)
        card.layoutIfNeeded()
        inline.layoutIfNeeded()
        func findWeb(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap(findWeb).first
        }
        guard var cardWeb = findWeb(card), var inlineWeb = findWeb(inline) else {
            throw QAFailure(message: "verified content-class runtime hooks did not attach both renderers")
        }
        func waitForBoth(_ track: String) async throws {
            for _ in 0..<100 {
                let js = "document.querySelector('#lyrics')?.textContent.includes('\(track)') === true"
                // Receiving the next song's DOM does not mean its first frame
                // has selected a visible caption yet. A tap requires that row.
                let visibleCaption = """
                (() => { const row = document.querySelector('#lyrics .inline-visible');
                  return row?.textContent.includes('\(track)') === true
                    && row.getClientRects().length > 0
                    && Number(getComputedStyle(row).opacity) > .99; })()
                """
                // Production can replace a slow/terminated WebKit renderer.
                // Assert against the live UI, never a detached cached WKWebView.
                if let currentCard = findWeb(card), let currentInline = findWeb(inline) {
                    cardWeb = currentCard
                    inlineWeb = currentInline
                    if (try await cardWeb.evaluateJavaScript(js)) as? Bool == true,
                       (try await inlineWeb.evaluateJavaScript(js)) as? Bool == true,
                       (try await inlineWeb.evaluateJavaScript(visibleCaption)) as? Bool == true { return }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            var details = ["embedded lyric generations did not converge for \(track)"]
            for (name, view, cachedWeb) in [("card", card, cardWeb), ("inline", inline, inlineWeb)] as [(String, UIView, WKWebView)] {
                let current = findWeb(view)
                let content = try? await current?.evaluateJavaScript("JSON.stringify({ready:!!window.SpicyNative,text:document.querySelector('#lyrics')?.textContent,busy:document.querySelector('#app')?.getAttribute('aria-busy'),width:innerWidth,height:innerHeight})")
                details.append("\(name) frame=\(view.frame) alpha=\(view.alpha) hidden=\(view.isHidden) root=\(root.view.bounds) window=\(String(describing: view.window?.bounds)) sameWeb=\(current === cachedWeb) content=\(String(describing: content))")
            }
            details.append(QADiagnostics.snapshot())
            throw QAFailure(message: details.joined(separator: "\n"))
        }
        try await waitForBoth("track-3")
        for _ in 0..<30 {
            if cardWeb.alpha > 0.99 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard cardWeb.alpha > 0.99 else { throw QAFailure(message: "preview was not revealed before the full-card check") }
        let fullCardImage = UIGraphicsImageRenderer(bounds: root.view.bounds).image { _ in
            root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
        }
        try fullCardImage.pngData()?.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qa-card-bleed.png"))
        let paintedCard = cardWeb.convert(cardWeb.bounds, to: cardShell)
        guard abs(paintedCard.minX) < 1, abs(paintedCard.minY) < 1,
              abs(paintedCard.width - cardShell.bounds.width) < 1,
              abs(paintedCard.height - cardShell.bounds.height) < 1 else {
            throw QAFailure(message: "preview artwork leaves the native card frame exposed: renderer=\(paintedCard), card=\(cardShell.bounds)")
        }
        checks.append("preview renderer reaches the entire native rounded card without changing content bounds")
        let contentRect = cardWeb.convert(card.bounds, from: card)
        let contentAligned = try await cardWeb.evaluateJavaScript("""
        (() => { const r=document.querySelector('.stage').getBoundingClientRect();
          return Math.abs(r.x-\(contentRect.minX))<1 && Math.abs(r.y-\(contentRect.minY))<1
            && Math.abs(r.width-\(contentRect.width))<1 && Math.abs(r.height-\(contentRect.height))<1; })()
        """)
        let contentHit = root.view.hitTest(card.convert(CGPoint(x: card.bounds.midX, y: card.bounds.midY), to: root.view), with: nil)
        let expandHit = root.view.hitTest(header.expandButtonContainerView.convert(CGPoint(x: 22, y: 20), to: root.view), with: nil)
        guard contentAligned as? Bool == true, contentHit?.isDescendant(of: cardWeb) == true,
              expandHit?.accessibilityIdentifier == "spicy-preview-expand",
              cardShell.clipsToBounds, cardShell.layer.cornerRadius == 18,
              header.alpha == 1, heading.alpha == 1 else {
            throw QAFailure(message: "full-card backdrop changed lyric bounds, native header interaction or rounded clipping: aligned=\(contentAligned), contentHit=\(String(describing: contentHit)), expandHit=\(String(describing: expandHit))")
        }
        checks.append("full-card artwork preserves native header/expand hit testing, rounded clipping and inner lyric geometry")
        cardShell.frame.size.height = 424
        cardShell.setNeedsLayout(); cardShell.layoutIfNeeded()
        for _ in 0..<30 {
            if (try await cardWeb.evaluateJavaScript("Math.abs(document.querySelector('.stage').getBoundingClientRect().height-352)<1")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard cardWeb.convert(cardWeb.bounds, to: cardShell).height == 424,
              (try await cardWeb.evaluateJavaScript("Math.abs(document.querySelector('.stage').getBoundingClientRect().height-352)<1")) as? Bool == true else {
            throw QAFailure(message: "native card resize left a stale artwork or lyric-content boundary")
        }
        cardShell.frame.size.height = 392
        cardShell.setNeedsLayout(); cardShell.layoutIfNeeded()
        checks.append("native card resizing updates the full backdrop and separate lyric slot together")
        let startupRestarts = QADiagnostics.snapshot().components(separatedBy: restartMarker).count - restartsBeforeSetup
        if startupRestarts > 0 {
            // A cold simulator may already have used the host's two permitted
            // startup recoveries. A deliberate third termination before its
            // existing 20-second stability interval correctly selects native
            // fallback, not the recovery case this test is meant to exercise.
            // Require the same live views to remain healthy through that window;
            // do not reset private state or relax the production recovery limit.
            let stableUntil = ProcessInfo.processInfo.systemUptime + 21
            while ProcessInfo.processInfo.systemUptime < stableUntil {
                guard findWeb(card) === cardWeb, findWeb(inline) === inlineWeb,
                      (try await cardWeb.evaluateJavaScript("Boolean(window.SpicyNative && document.querySelector('#lyrics')?.textContent.includes('track-3'))")) as? Bool == true,
                      (try await inlineWeb.evaluateJavaScript("Boolean(window.SpicyNative && document.querySelector('#lyrics')?.textContent.includes('track-3'))")) as? Bool == true else {
                    throw QAFailure(message: "startup-recovered compact renderers did not remain stable before termination testing")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            checks.append("compact renderers remained healthy through the existing stability interval after \(startupRestarts) startup recoveries")
        }
        let oldCardWeb = cardWeb
        let oldInlineWeb = inlineWeb
        // Exercise the public WKNavigationDelegate termination callback on the
        // production host. This deliberately tests lifecycle handling, not an
        // actual OS process kill; the replaced renderer must show current lyrics.
        cardWeb.navigationDelegate?.webViewWebContentProcessDidTerminate?(cardWeb)
        inlineWeb.navigationDelegate?.webViewWebContentProcessDidTerminate?(inlineWeb)
        try await waitForBoth("track-3")
        guard cardWeb !== oldCardWeb, inlineWeb !== oldInlineWeb else {
            throw QAFailure(message: "renderer termination did not replace the embedded WebKit views")
        }
        checks.append("both compact surfaces recover current lyrics after renderer termination callback")
        header.setNeedsLayout(); header.layoutIfNeeded()
        guard original.alpha == 0, originalInline.alpha == 0, header.alpha == 1,
              card.bounds.height == 320, inline.bounds.height == 52, !originalTap.isEnabled else {
            throw QAFailure(message: "replacement must preserve native surrounding controls and intrinsic bounds")
        }
        originalInline.alpha = 1 // native fade-in runs AFTER replacement layout
        let lateNativeChild = UILabel(frame: inline.bounds)
        lateNativeChild.text = "A LATE ORIGINAL MUST NOT OVERLAP"
        inline.addSubview(lateNativeChild)
        lateNativeChild.alpha = 1
        guard originalInline.layer.mask != nil, lateNativeChild.layer.mask != nil else {
            throw QAFailure(message: "native redraw or child insertion can draw above the replacement")
        }
        checks.append("native alpha redraw and late child insertion stay suppressed without collapsing layout")
        for (mode, web) in [("card", cardWeb), ("inline", inlineWeb)] {
            let js = """
            (() => document.documentElement.dataset.surface === '\(mode)'
              && getComputedStyle(document.querySelector('.player-bar')).display === 'none'
              && getComputedStyle(document.body).backgroundColor === 'rgba(0, 0, 0, 0)'
              && [...document.querySelectorAll('.lyric-line')].filter(e => e.getClientRects().length)
                .every(e => e.getBoundingClientRect().right <= innerWidth + 1))()
            """
            guard (try await web.evaluateJavaScript(js)) as? Bool == true else {
                throw QAFailure(message: "\(mode) compact layout regressed")
            }
            if mode == "inline" {
                let captionIsOneRow = try await web.evaluateJavaScript("""
                (() => { const text=document.querySelector('.inline-visible .line-text');
                  const range=document.createRange(); range.selectNodeContents(text);
                  const rects=[...range.getClientRects()];
                  return getComputedStyle(text).textOverflow !== 'ellipsis'
                    && rects.length > 0 && rects.every(r => r.top >= -1
                      && r.bottom <= innerHeight + 1 && r.left >= -1 && r.right <= innerWidth + 1); })()
                """)
                guard captionIsOneRow as? Bool == true else {
                    throw QAFailure(message: "timed caption token wraps below the visible native slot")
                }
                checks.append("caption glyphs fit the native slot without ellipsis or clipped rows")
            }
            let image = try await web.takeSnapshot(configuration: nil)
            let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("qa-\(mode).png")
            try image.pngData()?.write(to: path)
        }
        let contextImage = UIGraphicsImageRenderer(bounds: root.view.bounds).image { _ in
            root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
        }
        let contextPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qa-embedded-context.png")
        try contextImage.pngData()?.write(to: contextPath)
        inline.frame.size = CGSize(width: 280, height: 48)
        inline.setNeedsLayout(); inline.layoutIfNeeded()
        _ = try await inlineWeb.evaluateJavaScript("SpicyNative.receive({type:'bootstrap',payload:{surface:'inline',preferences:{fontSize:126}}})")
        try await Task.sleep(nanoseconds: 300_000_000)
        let captionFits = try await inlineWeb.evaluateJavaScript("""
        (() => { const text=document.querySelector('.inline-visible .line-text').getBoundingClientRect();
          return text.top >= -1 && text.bottom <= innerHeight + 1; })()
        """)
        guard captionFits as? Bool == true else { throw QAFailure(message: "enlarged native caption clips glyph rows") }
        checks.append("enlarged caption fits a short native lyric slot without clipped glyph rows")
        // Both non-video paths must attach, not just the Canvas test double.
        for view in [QAStillLyricsView(), QALegacyLyricsView(), QAMigratedCanvasLyricsView()] as [UIView] {
            view.frame = inline.frame
            root.view.addSubview(view)
            view.setNeedsLayout(); view.layoutIfNeeded()
            guard findWeb(view) != nil else { throw QAFailure(message: "non-Canvas caption did not attach") }
            view.removeFromSuperview()
            guard findWeb(view) == nil else { throw QAFailure(message: "non-Canvas caption leaked its renderer") }
        }
        checks.append("still-artwork, legacy and migrated Canvas caption hooks attach and detach")
        SpicyLyricsPlaybackBridge.shared.onSkip = nil
        _ = SpicyLyricsPlaybackBridge.shared.perform(command: "next")
        try await waitForBoth("track-4")
        checks.append("card and above-title lyric share current generation, real renderer and native bounds")
        _ = try await inlineWeb.evaluateJavaScript("document.querySelector('.inline-visible').click()")
        try await waitFor("inline tap opens Spicy directly without native lyric controller", "document.querySelector('#lyrics').textContent.includes('track-4')")
        SpicyLyricsPlaybackBridge.shared.payloadReads = 0
        NotificationCenter.default.post(name: .spicyLyricsPlaybackStateDidChange, object: nil)
        let visibleReads = SpicyLyricsPlaybackBridge.shared.payloadReads
        guard visibleReads == 1 else {
            throw QAFailure(message: "covered lyric views still request playback: expected 1 visible consumer, got \(visibleReads)")
        }
        checks.append("covered caption and preview stop requesting playback while fullscreen owns the scene")
        for embeddedWeb in [cardWeb, inlineWeb] {
            _ = try await embeddedWeb.evaluateJavaScript("""
            window.qaVisibleEvents = 0;
            (() => { const receive = SpicyNative.receive.bind(SpicyNative);
              SpicyNative.receive = message => {
                if (message.type === 'lifecycle' && message.payload.state === 'visible') window.qaVisibleEvents++;
                return receive(message);
              }; })();
            """)
        }
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(nanoseconds: 700_000_000)
        for embeddedWeb in [cardWeb, inlineWeb] {
            let visibleEvents = try await embeddedWeb.evaluateJavaScript("window.qaVisibleEvents") as? Int
            guard visibleEvents == 0 else {
                throw QAFailure(message: "foreground followups woke a covered renderer: visible events=\(String(describing: visibleEvents))")
            }
        }
        checks.append("foreground followups leave covered renderers suspended")
        _ = try await evaluate("document.querySelector('#next-button').click()")
        try await waitFor("skipping inside fullscreen loads the next generation", "document.querySelector('#lyrics').textContent.includes('track-5')")
        SpicyLyricsPlaybackBridge.shared.position = 22_000
        NotificationCenter.default.post(name: .spicyLyricsPlaybackStateDidChange, object: nil)
        try await waitFor("visible fullscreen keeps receiving playback while embedded views sleep", "Number(document.querySelector('#seek').value) === 22000")
        SpicyLyricsFullscreenCoordinator.shared.close()
        try await Task.sleep(nanoseconds: 500_000_000)
        guard card.window != nil else { throw QAFailure(message: "closing compact entry dismissed Now Playing") }
        try await waitForBoth("track-5")
        SpicyLyricsPlaybackBridge.shared.payloadReads = 0
        NotificationCenter.default.post(name: .spicyLyricsPlaybackStateDidChange, object: nil)
        guard SpicyLyricsPlaybackBridge.shared.payloadReads == 2 else {
            throw QAFailure(message: "closing fullscreen did not restore exactly the two embedded playback consumers")
        }
        var resumedAtCurrentPosition = false
        for _ in 0..<30 {
            let current = "Number(document.querySelector('#seek').value) === 22000"
            if (try await cardWeb.evaluateJavaScript(current)) as? Bool == true,
               (try await inlineWeb.evaluateJavaScript(current)) as? Bool == true {
                resumedAtCurrentPosition = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard resumedAtCurrentPosition else {
            throw QAFailure(message: "embedded lyrics resumed from a stale position after fullscreen closed")
        }
        try await waitForBoth("track-5")
        checks.append("preview and caption resume from fresh playback after fullscreen closes")
        // A native track refresh may replace every child of the same caption
        // container while fullscreen covers it. Exercise that UIKit operation,
        // not a synthetic renderer message or a private host-state mutation.
        let replacementCaption = UILabel(frame: inline.bounds)
        replacementCaption.text = "NEW NATIVE CAPTION MUST NOT OVERLAP"
        _ = try await inlineWeb.evaluateJavaScript("document.querySelector('.inline-visible').click()")
        try await waitFor("caption reopens fullscreen after an in-screen skip", "document.querySelector('#lyrics').textContent.includes('track-5')")
        SpicyLyricsPlaybackBridge.shared.onSkip = {
            inline.subviews.forEach { $0.removeFromSuperview() }
            inline.addSubview(replacementCaption)
            inline.setNeedsLayout(); inline.layoutIfNeeded()
        }
        _ = try await evaluate("document.querySelector('#next-button').click()")
        try await waitFor("fullscreen survives native caption child replacement on skip", "document.querySelector('#lyrics').textContent.includes('track-6')")
        SpicyLyricsPlaybackBridge.shared.onSkip = nil
        SpicyLyricsFullscreenCoordinator.shared.close()
        try await Task.sleep(nanoseconds: 500_000_000)
        let rebuiltContext = UIGraphicsImageRenderer(bounds: root.view.bounds).image { _ in
            root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
        }
        let rebuiltPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qa-caption-after-skip.png")
        try rebuiltContext.pngData()?.write(to: rebuiltPath)
        guard findWeb(inline) === inlineWeb, inlineWeb.window === inline.window else {
            throw QAFailure(message: "native caption child replacement orphaned the live renderer: liveWeb=\(findWeb(inline) != nil), cachedWebAttached=\(inlineWeb.window != nil), nativeAlpha=\(replacementCaption.alpha), nativeMasked=\(replacementCaption.layer.mask != nil)")
        }
        try await waitForBoth("track-6")
        let resumedCaption = try await inlineWeb.evaluateJavaScript("""
        (() => { const line = document.querySelector('#lyrics .inline-visible');
          const bounds = line?.getBoundingClientRect();
          return line?.textContent.includes('track-6') && bounds.height > 0
            && bounds.top >= -1 && bounds.bottom <= innerHeight + 1
            && getComputedStyle(line).opacity === '1'; })()
        """)
        guard resumedCaption as? Bool == true, replacementCaption.layer.mask != nil else {
            throw QAFailure(message: "caption did not visibly recover the new song after fullscreen skip and native rebuild")
        }
        checks.append("native caption child replacement preserves one live renderer and visibly resumes the skipped-to song")
        guard let expand = header.expandButtonContainerView.subviews.compactMap({ $0 as? UIButton })
            .first(where: { $0.accessibilityIdentifier == "spicy-preview-expand" }),
              header.expandButtonContainerView.hitTest(CGPoint(x: 22, y: 20), with: nil) === expand else {
            throw QAFailure(message: "native expand target was not replaced before its zoom action")
        }
        expand.sendActions(for: .touchUpInside)
        try await waitFor("native header expand enters Spicy directly", "document.querySelector('#lyrics').textContent.includes('track-6')")
        guard nativeExpandCount == 0 else { throw QAFailure(message: "native zoom action fired") }
        SpicyLyricsFullscreenCoordinator.shared.close()
        try await Task.sleep(nanoseconds: 500_000_000)
        QALyricsPreference.enabled = false
        card.setNeedsLayout(); card.layoutIfNeeded()
        inline.setNeedsLayout(); inline.layoutIfNeeded()
        header.setNeedsLayout(); header.layoutIfNeeded()
        guard findWeb(card) == nil, findWeb(inline) == nil, original.alpha == 1,
              originalInline.alpha == 1, !original.accessibilityElementsHidden,
              originalInline.layer.mask == nil, lateNativeChild.layer.mask == nil, originalTap.isEnabled,
              replacementCaption.alpha == 1, replacementCaption.layer.mask == nil,
              card.clipsToBounds, cardShell.stackView.clipsToBounds, header.layer.zPosition == 0,
              !header.expandButtonContainerView.subviews.contains(where: { $0.accessibilityIdentifier == "spicy-preview-expand" }) else {
            throw QAFailure(message: "embedded detach did not restore native content and clean up WebKit")
        }
        cardShell.removeFromSuperview(); inline.removeFromSuperview()
        checks.append("embedded detach restores native content and removes WebKit/child controllers")
        SpicyLyricsFullscreenCoordinator.shared.open(from: root)
        let preparingWindow = scene.keyWindow
        SpicyLyricsFullscreenCoordinator.shared.close()
        // Match the existing close test's observable three-second completion
        // bound. A fixed 500ms sample raced the compositor: the window really
        // closed at 767ms on the cold simulator, after that sample had failed.
        let cancelStarted = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - cancelStarted < 3 {
            if preparingWindow?.isHidden == true, preparingWindow?.rootViewController == nil,
               scene.keyWindow?.rootViewController === root { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard preparingWindow?.isHidden == true, preparingWindow?.rootViewController == nil,
              scene.keyWindow?.rootViewController === root else {
            throw QAFailure(message: "canceling during preparation must dispose its window and restore the player within 3 seconds")
        }
        checks.append("canceling during preparation disposes its window and restores the player in \(ProcessInfo.processInfo.systemUptime - cancelStarted)s")
        SpicyLyricsFullscreenCoordinator.shared.open(from: root)
        try await waitFor("reopen after interrupted preparation loads current lyrics", "document.querySelector('#lyrics').textContent.includes('track-6')")
        SpicyLyricsFullscreenCoordinator.shared.close()
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    func testBackgroundPreferences() async throws {
        let full = UIViewController(), preview = UIViewController()
        for (index, child) in [full, preview].enumerated() {
            source.addChild(child)
            child.view.frame = CGRect(x: 0, y: 40 + index * 350, width: 360, height: 340)
            source.view.addSubview(child.view)
            child.didMove(toParent: source)
        }
        var fullHost = SpicyLyricsFullscreenHost(controller: full)
        let previewHost = SpicyLyricsFullscreenHost(controller: preview, surface: .card)
        defer {
            fullHost.detach(); previewHost.detach()
            for child in [full, preview] {
                child.willMove(toParent: nil); child.view.removeFromSuperview(); child.removeFromParent()
            }
        }
        guard fullHost.attach(), previewHost.attach() else { throw QAFailure(message: "settings hosts did not attach") }
        func web(_ controller: UIViewController) -> WKWebView? {
            controller.view.subviews.compactMap { $0 as? WKWebView }.first
        }
        func require(_ controller: UIViewController, _ predicate: String, _ label: String) async throws {
            for _ in 0..<100 {
                if let current = web(controller),
                   (try? await current.evaluateJavaScript("Boolean(window.SpicyNative && (\(predicate)))")) as? Bool == true { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let detail = try? await web(controller)?.evaluateJavaScript("JSON.stringify({style:document.querySelector('#background-style')?.value,speed:document.querySelector('#background-speed')?.value,dynamic:document.querySelector('#background-toggle')?.checked})")
            throw QAFailure(message: "\(label): \(String(describing: detail))")
        }
        try await require(full, "document.querySelector('#lyrics .lyric-line')", "fullscreen settings ready")
        try await require(preview, "document.querySelector('#lyrics .lyric-line')", "preview settings ready")
        previewHost.setContentFrame(CGRect(x: 16, y: 40, width: 328, height: 280))
        _ = try await web(preview)?.evaluateJavaScript("window.qaPreferenceLine = document.querySelector('#lyrics .lyric-line'); true")
        _ = try await web(full)?.evaluateJavaScript("""
        (() => {
          document.querySelector('#settings-button').click();
          const style=document.querySelector('#background-style'); style.value='gradient'; style.dispatchEvent(new Event('change',{bubbles:true}));
          const speed=document.querySelector('#background-speed'); speed.value='175'; speed.dispatchEvent(new Event('input',{bubbles:true})); speed.dispatchEvent(new Event('change',{bubbles:true}));
          const dynamic=document.querySelector('#background-toggle'); dynamic.checked=false; dynamic.dispatchEvent(new Event('change',{bubbles:true})); return true;
        })()
        """)
        let saved = "document.querySelector('#background-style').value === 'gradient' && document.querySelector('#background-speed').value === '175' && !document.querySelector('#background-toggle').checked"
        try await require(preview, saved, "live preview did not receive saved background preferences")
        try await require(preview, "window.qaPreferenceLine === document.querySelector('#lyrics .lyric-line') && getComputedStyle(document.documentElement).getPropertyValue('--card-content-y') === '40px'", "settings reset preview lyrics or native layout")
        fullHost.detach()
        fullHost = SpicyLyricsFullscreenHost(controller: full)
        guard fullHost.attach() else { throw QAFailure(message: "settings reopen did not attach") }
        try await require(full, saved, "background preferences did not survive a new native host")
        _ = try await web(full)?.evaluateJavaScript("""
        (() => {
          const style=document.querySelector('#background-style'); style.value='artwork'; style.dispatchEvent(new Event('change',{bubbles:true}));
          const speed=document.querySelector('#background-speed'); speed.value='100'; speed.dispatchEvent(new Event('input',{bubbles:true})); speed.dispatchEvent(new Event('change',{bubbles:true}));
          const dynamic=document.querySelector('#background-toggle'); dynamic.checked=true; dynamic.dispatchEvent(new Event('change',{bubbles:true})); return true;
        })()
        """)
        try await require(preview, "document.querySelector('#background-style').value === 'artwork' && document.querySelector('#background-speed').value === '100' && document.querySelector('#background-toggle').checked", "restored settings did not reach preview")
        checks.append("native settings persist style, speed and dynamic mode across hosts; live preview retains its lyric DOM and native content frame")
    }

    func run() async {
        do {
            checkpoint("testing native background preferences")
            try await testBackgroundPreferences()
            checkpoint("starting native availability")
            try await testNativeAvailability()
            checkpoint("native availability and actual display capture passed")
            // Keep the isolated renderer assertions independent of the later
            // external display-capture handshake and native lifecycle fixtures.
            try await testRendererTransitions(baseline: true)
            try await testRendererTransitions(baseline: false)
            checkpoint("current WebKit transitions finished with \(rendererFailures.count) failures; testing independent UIKit lifecycle")
            SpicyLyricsFullscreenCoordinator.shared.attach(to: source)
            guard let preparing = scene.keyWindow, preparing.rootViewController !== source,
                  preparing.rootViewController?.view.subviews.count == 2 else {
                throw QAFailure(message: "entry must cover native lyrics before renderer loading")
            }
            preparing.layoutIfNeeded()
            guard let entry = preparing.rootViewController?.view.subviews.first(where: { !($0 is WKWebView) }),
                  let entrySnapshot = entry.subviews.first(where: { !($0 is UIButton) }) else {
                throw QAFailure(message: "entry must preserve the previous screen while preparing")
            }
            let entryBounds = entry.convert(entry.bounds, to: preparing)
            let snapshotBounds = entrySnapshot.convert(entrySnapshot.bounds, to: preparing)
            guard abs(entryBounds.width - preparing.bounds.width) < 1,
                  abs(entryBounds.height - preparing.bounds.height) < 1,
                  abs(snapshotBounds.width - preparing.bounds.width) < 1,
                  abs(snapshotBounds.height - preparing.bounds.height) < 1,
                  abs(snapshotBounds.minX) < 1, abs(snapshotBounds.minY) < 1 else {
                throw QAFailure(message: "entry zoomed before reveal: window=\(preparing.bounds), cover=\(entryBounds), snapshot=\(snapshotBounds)")
            }
            checks.append("preparation preserves the source screen at 1:1 size before reveal")
            try await waitFor("initial lyrics loaded", "document.querySelector('#lyrics').textContent.includes('track-1')")
            try await Task.sleep(nanoseconds: 500_000_000)
            guard webView()?.alpha == 1, webView()?.transform == .identity,
                  scene.keyWindow?.rootViewController?.view.subviews.count == 1 else {
                throw QAFailure(message: "prepared transition must remove snapshot and settle renderer")
            }
            checks.append("prepared UIKit transition completes and memory-only cover is removed")
            _ = try await evaluate("document.querySelector('#play-button').click()")
            try await waitFor("pause dispatch and observed label", "document.querySelector('#play-button').getAttribute('aria-label') === 'Play' && !document.querySelector('#play-button').classList.contains('pending')")
            guard SpicyLyricsPlaybackBridge.shared.paused else { throw QAFailure(message: "pause did not reach native host") }
            _ = try await evaluate("document.querySelector('#play-button').click()")
            try await waitFor("resume dispatch", "document.querySelector('#play-button').getAttribute('aria-label') === 'Pause'")
            SpicyLyricsPlaybackBridge.shared.onSkip = { [weak source] in source?.dismiss(animated: false) }
            _ = try await evaluate("document.querySelector('#next-button').click()")
            try await waitFor("next lyrics survive original controller dismissal", "document.querySelector('#title').textContent === 'Track 2' && document.querySelector('#lyrics').textContent.includes('track-2')")
            try await Task.sleep(nanoseconds: 500_000_000)
            guard source.viewIfLoaded?.window == nil else { throw QAFailure(message: "fixture did not dismiss the track-scoped native screen") }
            _ = try await evaluate("document.querySelector('#previous-button').click()")
            try await waitFor("previous loads destination lyrics", "document.querySelector('#lyrics').textContent.includes('track-3')")
            for (index, mode) in ["shuffle", "smart", "off"].enumerated() {
                _ = try await evaluate("document.querySelector('#shuffle-button').click()")
                try await waitFor("shuffle mode \(index)", "document.querySelector('#shuffle-button').dataset.mode === '\(mode)' && !document.querySelector('#shuffle-button').classList.contains('pending')")
            }
            for mode in ["context", "track", "off"] {
                _ = try await evaluate("document.querySelector('#repeat-button').click()")
                try await waitFor("repeat \(mode)", "document.querySelector('#repeat-button').dataset.mode === '\(mode)' && !document.querySelector('#repeat-button').classList.contains('pending')")
            }
            try await waitFor("long lyrics and all controls contained in WebKit", """
            (() => {
              const els = [...document.querySelectorAll('.lyric-line,.token,.transport button,.timeline,#settings-button')];
              return els.every(e => { const r=e.getBoundingClientRect(); return r.left >= -1 && r.right <= innerWidth+1; })
                && document.querySelectorAll('.word-group.breakable').length > 0;
            })()
            """)
            try await snapshot("qa-portrait")
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            try await waitFor("rotation keeps all transport controls on screen", """
            (() => innerWidth > innerHeight && [...document.querySelectorAll('.transport button,.timeline,#settings-button')]
              .every(e => { const r=e.getBoundingClientRect(); return r.left >= -1 && r.right <= innerWidth+1
                && r.top >= -1 && r.bottom <= innerHeight+1; }))()
            """)
            try await waitFor("landscape metadata appears only in the bottom player", """
            (() => { const title=document.querySelector('#title');
              return !title.getClientRects().length && document.querySelector('#mini-title').textContent==='Track 3'
                && document.querySelector('.mini-track').getBoundingClientRect().height > 0; })()
            """)
            try await waitForSettledLandscape()
            try await snapshot("qa-landscape")
            try await captureSimulatorScreen()
            checkpoint("landscape display captured; closing fullscreen")
            guard let overlay = scene.keyWindow else { throw QAFailure(message: "close has no persistent window") }
            _ = try await evaluate("document.querySelector('#close-button').click()")
            // Check the real completion state: a cold simulator can deliver the
            // animation completion after an arbitrary half-second sleep expires.
            let closeStarted = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - closeStarted < 3 {
                if overlay.isHidden, overlay.rootViewController == nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard overlay.isHidden, overlay.rootViewController == nil,
                  let restoredWindow = scene.keyWindow, restoredWindow !== overlay,
                  restoredWindow.rootViewController != nil else {
                throw QAFailure(message: "close must dispose persistent window and restore the original window within 3 seconds")
            }
            checks.append("close disposes persistent window and restores original window in \(ProcessInfo.processInfo.systemUptime - closeStarted)s")
            checkpoint("fullscreen close passed; starting embedded lifecycle")
            try await testEmbeddedSurfaces()
            checkpoint("embedded lifecycle passed; finishing suite")
            guard rendererFailures.isEmpty else {
                throw QAFailure(message: rendererFailures.joined(separator: "; "))
            }
            finish(result: "PASS")
        } catch {
            finish(result: "FAIL: \(error)\n\(await failureDiagnostics())")
        }
    }
    func rendererTransitionPhase(_ phase: String, baseline: Bool) async throws -> [[String: Any]] {
        guard var root = scene.keyWindow?.rootViewController,
              let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: baseline ? "SpicyLyricsBefore" : "SpicyLyricsRenderer") else {
            throw QAFailure(message: "transition fixture has no root or renderer")
        }
        while let presented = root.presentedViewController { root = presented }
        guard root.viewIfLoaded?.window != nil else {
            throw QAFailure(message: "transition fixture controller must be on screen for frame sampling")
        }
        // Production has separate fixed-surface hosts, not one WKWebView that
        // rapidly alternates between caption/card/fullscreen for every test.
        // Give each independent case a fresh host at its final native size.
        // The real same-host track-skip/reopen stress tests still run below.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        let inline = phase == "inline" || phase.hasSuffix("-inline")
        let fullscreen = phase == "background" || phase == "highlight" || phase.hasSuffix("-fullscreen")
        let height: CGFloat = inline ? 52 : (phase == "background" || phase.hasSuffix("-fullscreen") ? 640 : (phase == "card-layout" ? 392 : 320))
        let surface = inline ? "inline" : (fullscreen ? "fullscreen" : "card")
        let web = WKWebView(frame: CGRect(x: 0, y: 100, width: 360, height: height), configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        root.view.addSubview(web)
        defer { web.removeFromSuperview() }
        func evaluateTransitionScript(_ script: String) async throws -> Any? {
            try await withCheckedThrowingContinuation { continuation in
                web.evaluateJavaScript(script) { value, error in
                    if let error = error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value) }
                }
            }
        }
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        var ready = false
        for _ in 0..<100 {
            if (try? await evaluateTransitionScript("Boolean(window.SpicyNative)")) as? Bool == true { ready = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard ready else { throw QAFailure(message: "transition renderer not ready") }
        _ = try await evaluateTransitionScript("window.SpicyNative.receive({type:'bootstrap',payload:{surface:'\(surface)',preferences:{fontSize:100,playbackOffset:0,dynamicBackground:false}}});true")
        for name in ["browser-fixture", "transition-checks"] {
            guard let file = Bundle.main.url(forResource: name, withExtension: "js") else {
                throw QAFailure(message: "missing isolated transition test")
            }
            _ = try await evaluateTransitionScript(String(contentsOf: file, encoding: .utf8) + "\n;true")
        }
        let script = """
        const frame = () => new Promise(requestAnimationFrame);
        let stable = 0;
        for (const deadline=performance.now()+5000; performance.now()<deadline && stable<6;) {
          await frame();
          const viewport = visualViewport;
          const matches = !document.hidden && Math.abs(innerWidth-width)<1 && Math.abs(innerHeight-height)<1
            && Math.abs(viewport.width-width)<1 && Math.abs(viewport.height-height)<1;
          stable = matches ? stable+1 : 0;
        }
        if (stable<6) throw new Error('Native/visual viewport did not settle before '+phase);
        try { return JSON.stringify(await runSpicyTransitionChecks(phase)); }
        catch (error) {
          return JSON.stringify([{name:phase+': isolated renderer fixture completes',pass:false,
            detail:{message:String(error),stack:String(error.stack||''),width:innerWidth,height:innerHeight,
              state:SpicyQA.inspect()}}]);
        }
        """
        // Await the actual viewport and the complete test promise. Test errors
        // remain failing rows so other independent cases can still be checked.
        let result: Any = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(script, arguments: ["phase": phase, "width": 360, "height": Double(height)], in: nil, in: .page) {
                continuation.resume(with: $0)
            }
        }
        guard let text = result as? String,
              let data = text.data(using: .utf8),
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw QAFailure(message: "no transition results for \(phase)")
        }
        return rows
    }

    func testRendererTransitions(baseline: Bool) async throws {
        var rows = [[String: Any]]()
        let desktopPhases = ["interlude", "dot-envelope", "paint", "motion", "emphasis", "type", "layout", "contrast"]
            .flatMap { phase in ["fullscreen", "card", "inline"].map { "desktop-\(phase)-\($0)" } }
            + ["desktop-shuffle-fullscreen", "desktop-backdrop-fullscreen"]
        let phases = baseline ? ["inline", "card"]
            : ["inline", "card", "background", "highlight", "card-layout"] + desktopPhases
        for phase in phases {
            let phaseRows = try await rendererTransitionPhase(phase, baseline: baseline)
            rows += phaseRows
            let reportURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(baseline ? "qa-renderer-baseline.json" : "qa-renderer-results.json")
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
            checkpoint("\(baseline ? "baseline" : "current") WebKit \(phase): \(phaseRows.filter { $0["pass"] as? Bool == true }.count)/\(phaseRows.count) checks passed")
        }
        var failures = [String]()
        for row in rows {
            let name = row["name"] as? String ?? "unnamed"
            let passed = row["pass"] as? Bool == true
            checks.append("\(baseline ? "BASELINE" : "CURRENT") \(passed ? "PASS" : "FAIL") WKWebView \(name): \(row["detail"] ?? "")")
            if !passed { failures.append(name) }
        }
        if baseline {
            guard failures.contains("caption changes blend through real intermediate frames"),
                  failures.contains("line-timed preview highlight fades rather than switching instantly") else {
                throw QAFailure(message: "historical renderer did not reproduce transition defects")
            }
        } else {
            // A rendered assertion failure still fails the complete run, but
            // must not conceal results from the independent hosting/lifecycle
            // fixtures that follow. Structural setup errors remain fatal.
            rendererFailures += failures
        }
    }

    func finish(result: String) {
        let report = ([result] + checks).joined(separator: "\n")
        print(report)
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("qa-result.txt")
        try? report.write(to: path, atomically: true, encoding: .utf8)
    }
}

final class QASceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var runner: QARunner?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        root.view.backgroundColor = .black
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let source = UIViewController()
            source.modalPresentationStyle = .fullScreen
            source.view.backgroundColor = .black
            root.present(source, animated: false) {
                let runner = QARunner(source: source, scene: scene)
                self.runner = runner
                Task { await runner.run() }
            }
        }
    }
}

final class QAAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "QA", sessionRole: session.role)
        configuration.delegateClass = QASceneDelegate.self
        return configuration
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(QAAppDelegate.self))
