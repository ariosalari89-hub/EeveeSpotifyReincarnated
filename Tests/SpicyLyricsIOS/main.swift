import UIKit
import WebKit

@objc(_TtC22Lyrics_CardElementImpl15CardContentView)
final class QACardContentView: UIView {}
@objc(_TtC17Canvas_CommonImpl26CanvasNowPlayingLyricsView)
final class QAInlineLyricsView: UIView {}

// Only Spotify and its network service are simulated. The full-screen owner,
// WebKit host, renderer and UIKit lifecycle below are the shipping sources.
func writeDebugLog(_ message: String) { print(message) }

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

    func sessionPayload() -> [String: Any]? {
        sequence += 1
        return [
            "generation": String(generation), "sequence": String(sequence),
            "trackId": "track-\(generation)", "positionMs": position, "durationMs": 180_000,
            "isPlaying": !paused, "isPaused": paused, "isAdvancing": false,
            "playbackRate": 1, "requiresFreshObservation": false,
            "shuffleEnabled": shuffle != 0, "shuffleMode": ["off", "shuffle", "smart"][shuffle],
            "smartShuffleAvailable": true, "repeatMode": ["off", "context", "track"][repeatMode],
            "track": ["id": "track-\(generation)", "title": "Track \(generation)", "artist": "Lyric layout sample"]
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
    init(source: UIViewController, scene: UIWindowScene) { self.source = source; self.scene = scene }

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

    func testEmbeddedSurfaces() async throws {
        guard let root = scene.keyWindow?.rootViewController else { throw QAFailure(message: "missing native player root") }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        try await Task.sleep(nanoseconds: 600_000_000)
        var enabled = true
        SpicyLyricsEmbeddedSurfaces.install { enabled }
        let width = min(360, root.view.bounds.width - 32)
        let card = QACardContentView(frame: CGRect(x: 16, y: 220, width: width, height: 320))
        card.backgroundColor = UIColor(red: 0.50, green: 0.38, blue: 0.56, alpha: 1)
        let original = UILabel(frame: card.bounds)
        original.text = "ORIGINAL NATIVE LYRICS MUST NOT FLASH"
        card.addSubview(original)
        let header = UILabel(frame: CGRect(x: 16, y: 180, width: width, height: 40))
        header.text = "Lyrics · native header/share/expand"
        header.textColor = .white
        root.view.addSubview(header)
        root.view.addSubview(card)
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
        guard let cardWeb = findWeb(card), let inlineWeb = findWeb(inline) else {
            throw QAFailure(message: "verified content-class runtime hooks did not attach both renderers")
        }
        func waitForBoth(_ track: String) async throws {
            for _ in 0..<100 {
                let js = "document.querySelector('#lyrics')?.textContent.includes('\(track)') === true"
                if (try await cardWeb.evaluateJavaScript(js)) as? Bool == true,
                   (try await inlineWeb.evaluateJavaScript(js)) as? Bool == true { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw QAFailure(message: "embedded lyric generations did not converge")
        }
        try await waitForBoth("track-3")
        guard original.alpha == 0, originalInline.alpha == 0, header.alpha == 1,
              card.bounds.height == 320, inline.bounds.height == 52 else {
            throw QAFailure(message: "replacement must preserve native surrounding controls and intrinsic bounds")
        }
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
        SpicyLyricsPlaybackBridge.shared.onSkip = nil
        _ = SpicyLyricsPlaybackBridge.shared.perform(command: "next")
        try await waitForBoth("track-4")
        checks.append("card and above-title lyric share current generation, real renderer and native bounds")
        _ = try await inlineWeb.evaluateJavaScript("document.querySelector('.inline-visible').click()")
        try await waitFor("inline tap opens Spicy directly without native lyric controller", "document.querySelector('#lyrics').textContent.includes('track-4')")
        SpicyLyricsFullscreenCoordinator.shared.close()
        try await Task.sleep(nanoseconds: 500_000_000)
        guard card.window != nil else { throw QAFailure(message: "closing compact entry dismissed Now Playing") }
        enabled = false
        card.setNeedsLayout(); card.layoutIfNeeded()
        inline.setNeedsLayout(); inline.layoutIfNeeded()
        guard findWeb(card) == nil, findWeb(inline) == nil, original.alpha == 1,
              originalInline.alpha == 1, !original.accessibilityElementsHidden else {
            throw QAFailure(message: "embedded detach did not restore native content and clean up WebKit")
        }
        card.removeFromSuperview(); inline.removeFromSuperview(); header.removeFromSuperview()
        checks.append("embedded detach restores native content and removes WebKit/child controllers")
        SpicyLyricsFullscreenCoordinator.shared.open(from: root)
        let preparingWindow = scene.keyWindow
        SpicyLyricsFullscreenCoordinator.shared.close()
        try await Task.sleep(nanoseconds: 500_000_000)
        guard preparingWindow?.isHidden == true, scene.keyWindow?.rootViewController === root else {
            throw QAFailure(message: "canceling during preparation must restore the player")
        }
        SpicyLyricsFullscreenCoordinator.shared.open(from: root)
        try await waitFor("reopen after interrupted preparation loads current lyrics", "document.querySelector('#lyrics').textContent.includes('track-4')")
        SpicyLyricsFullscreenCoordinator.shared.close()
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    func run() async {
        do {
            SpicyLyricsFullscreenCoordinator.shared.attach(to: source)
            guard let preparing = scene.keyWindow, preparing.rootViewController !== source,
                  preparing.rootViewController?.view.subviews.count == 2 else {
                throw QAFailure(message: "entry must cover native lyrics before renderer loading")
            }
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
            try await waitFor("landscape title has room beside the lyrics", """
            (() => { const title=document.querySelector('#title');
              return title.textContent==='Track 3' && title.scrollWidth <= title.clientWidth; })()
            """)
            try await snapshot("qa-landscape")
            let overlay = scene.windows.first(where: { $0.isKeyWindow })
            _ = try await evaluate("document.querySelector('#close-button').click()")
            try await Task.sleep(nanoseconds: 500_000_000)
            guard overlay?.isHidden == true else { throw QAFailure(message: "close must dispose persistent window") }
            checks.append("close restores original window")
            try await testEmbeddedSurfaces()
            finish(result: "PASS")
        } catch {
            finish(result: "FAIL: \(error)")
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
