import Foundation
import UIKit
import WebKit

private final class SpicyLyricsRequestCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class SpicyLyricsFullscreenCoordinator {
    static let shared = SpicyLyricsFullscreenCoordinator()

    private let hosts = NSMapTable<UIViewController, SpicyLyricsFullscreenHost>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    private init() {}

    func attach(to controller: UIViewController) {
        guard hosts.object(forKey: controller) == nil else { return }
        let host = SpicyLyricsFullscreenHost(controller: controller)
        hosts.setObject(host, forKey: controller)
        if !host.attach() { hosts.removeObject(forKey: controller) }
    }

    func detach(from controller: UIViewController) {
        hosts.object(forKey: controller)?.detach()
        hosts.removeObject(forKey: controller)
    }
}

final class SpicyLyricsFullscreenHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private static let rendererProtocolVersion = 4

    private weak var controller: UIViewController?
    private var webView: WKWebView?
    private var playbackTimer: Timer?
    private var readyWatchdog: Timer?
    private var revealWatchdog: Timer?
    private var foregroundResyncTimer: Timer?
    private var lifecycleObservers = [NSObjectProtocol]()
    private var isReady = false
    private var isDetached = false
    private var activeTrackID = ""
    private var activeGeneration = ""
    private var lyricsRequestID = UUID()
    private var lyricsCancellation: SpicyLyricsRequestCancellation?

    init(controller: UIViewController) {
        self.controller = controller
        super.init()
    }

    @discardableResult
    func attach() -> Bool {
        guard let controller,
              let pageURL = BundleHelper.shared.resourceURL(
                "index",
                withExtension: "html",
                subdirectory: "SpicyLyricsRenderer"
              ) else {
            writeDebugLog("[SpicyRenderer] renderer bundle is missing; keeping native lyrics")
            return false
        }

        let contentController = WKUserContentController()
        contentController.add(self, name: "eevee")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.isScrollEnabled = false
        webView.allowsLinkPreview = false
        webView.accessibilityLabel = "Spicy Lyrics"
        // Load before the lyrics controller is presented. Keeping the native
        // view visible until WebKit is ready avoids the late full-screen pop
        // that occurred when the overlay was attached from viewDidAppear.
        webView.alpha = 0

        controller.view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor)
        ])
        controller.view.bringSubviewToFront(webView)
        self.webView = webView

        let directory = pageURL.deletingLastPathComponent()
        webView.loadFileURL(pageURL, allowingReadAccessTo: directory)

        lifecycleObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                SpicyLyricsPlaybackBridge.shared.suspendPlaybackClock()
                self?.emit(type: "lifecycle", payload: ["state": "hidden"])
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.resynchronizeAfterForeground()
            }
        ]

        readyWatchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, !self.isReady else { return }
            self.fallBackToNative(reason: "renderer did not become ready")
        }
        writeDebugLog("[SpicyRenderer] attached to full-screen lyrics")
        return true
    }

    func detach() {
        guard !isDetached else { return }
        isDetached = true
        playbackTimer?.invalidate()
        playbackTimer = nil
        readyWatchdog?.invalidate()
        readyWatchdog = nil
        revealWatchdog?.invalidate()
        revealWatchdog = nil
        foregroundResyncTimer?.invalidate()
        foregroundResyncTimer = nil
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
        lyricsCancellation?.cancel()
        lyricsCancellation = nil
        lyricsRequestID = UUID()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "eevee")
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "eevee", !isDetached,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        let requestID = body["requestId"] as? String ?? ""
        switch type {
        case "ready":
            let protocolVersion = (body["rendererProtocolVersion"] as? NSNumber)?.intValue ?? -1
            guard protocolVersion == Self.rendererProtocolVersion else {
                fallBackToNative(reason: "renderer protocol mismatch: \(protocolVersion)")
                return
            }
            writeDebugLog("[SpicyRenderer] ready protocol=\(protocolVersion)")
            rendererDidBecomeReady()
        case "close":
            sendCommandResult(requestID: requestID, accepted: true)
            close()
        case "seek":
            guard commandMatchesActiveGeneration(body) else {
                sendCommandResult(requestID: requestID, accepted: false)
                return
            }
            let milliseconds = (body["positionMs"] as? NSNumber)?.doubleValue ?? 0
            let accepted = SpicyLyricsPlaybackBridge.shared.perform(command: "seek", value: milliseconds / 1000)
            sendCommandResult(requestID: requestID, accepted: accepted)
        case "next", "previous":
            guard commandMatchesActiveGeneration(body) else {
                sendCommandResult(requestID: requestID, accepted: false)
                return
            }
            SpicyLyricsPlaybackBridge.shared.performSkip(command: type) { [weak self] accepted in
                DispatchQueue.main.async {
                    guard let self, !self.isDetached else { return }
                    self.sendCommandResult(requestID: requestID, accepted: accepted)
                    if accepted {
                        self.publishPlaybackAndTrack(forceTrack: true)
                    }
                }
            }
        case "togglePlay", "play", "pause", "toggleShuffle", "cycleRepeat":
            guard commandMatchesActiveGeneration(body) else {
                sendCommandResult(requestID: requestID, accepted: false)
                return
            }
            let accepted = SpicyLyricsPlaybackBridge.shared.perform(command: type)
            sendCommandResult(requestID: requestID, accepted: accepted)
        case "resync":
            resynchronizeAfterForeground()
            sendCommandResult(requestID: requestID, accepted: true)
        case "retryLyrics":
            requestLyrics(for: activeTrackID, force: true)
        case "setPreference":
            let key = body["key"] as? String ?? ""
            let accepted = persistPreference(key: key, value: body["value"])
            sendCommandResult(requestID: requestID, accepted: accepted)
        case "diagnostic":
            let kind = body["kind"] as? String ?? "unknown"
            let trackID = body["trackId"] as? String ?? ""
            let lyricsType = body["lyricsType"] as? String ?? "unknown"
            let lineCount = (body["lineCount"] as? NSNumber)?.intValue ?? -1
            let timedLineCount = (body["timedLineCount"] as? NSNumber)?.intValue ?? -1
            let firstStart = (body["firstStartMs"] as? NSNumber)?.doubleValue ?? -1
            let lastEnd = (body["lastEndMs"] as? NSNumber)?.doubleValue ?? -1
            let scale = (body["timeScale"] as? NSNumber)?.doubleValue ?? -1
            writeDebugLog(
                "[SpicyRenderer] \(kind) track=\(trackID) type=\(lyricsType) "
                + "lines=\(lineCount)/\(timedLineCount) range=\(firstStart)..\(lastEnd) scale=\(scale)"
            )
        default:
            sendCommandResult(requestID: requestID, accepted: false)
        }
    }

    private func rendererDidBecomeReady() {
        guard !isReady else { return }
        isReady = true
        readyWatchdog?.invalidate()
        readyWatchdog = nil

        emit(type: "bootstrap", payload: [
            "platform": "ios",
            "reduceMotion": UIAccessibility.isReduceMotionEnabled,
            "boldText": UIAccessibility.isBoldTextEnabled,
            "safeFallback": true,
            "preferences": rendererPreferences()
        ])

        publishPlaybackAndTrack(forceTrack: true)
        // Keep Spotify's already-present native surface in place until either
        // real lyrics arrive or a short watchdog decides a loading state is
        // preferable. This removes the empty/stale one-frame transition.
        revealWatchdog = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.revealRenderer()
        }
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.publishPlaybackAndTrack(forceTrack: false)
        }
        RunLoop.main.add(playbackTimer!, forMode: .common)
    }

    private func publishPlaybackAndTrack(forceTrack: Bool, requiresFreshSample: Bool = false) {
        guard isReady, !isDetached else { return }
        let liveID = SpicyLyricsPlaybackBridge.shared.currentTrackID() ?? ""
        let playback = requiresFreshSample
            ? SpicyLyricsPlaybackBridge.shared.foregroundPayload()
            : SpicyLyricsPlaybackBridge.shared.playbackPayload()

        let bridgeID = playback["trackId"] as? String ?? ""
        let currentID = liveID.isEmpty ? bridgeID : liveID
        let generation = playback["generation"] as? String ?? ""
        guard !currentID.isEmpty else { return }

        let changedTrack = currentID != activeTrackID
            || (!generation.isEmpty && generation != activeGeneration)
        if forceTrack || changedTrack {
            activeTrackID = currentID
            activeGeneration = generation
            var track = SpicyLyricsPlaybackBridge.shared.trackPayload()
            track["generation"] = generation
            emit(type: "track", payload: track)
        }
        // Desktop Spicy Lyrics has one canonical millisecond player clock. Give
        // the renderer that clock before an asynchronously fetched lyric can be
        // delivered. The renderer no longer depends on this ordering for unit
        // conversion, but preserving it prevents a loading/ready transition
        // from briefly painting against a stale duration or position.
        emit(type: "playback", payload: playback)
        if changedTrack {
            requestLyrics(for: currentID, generation: generation, force: false)
        }
    }

    private func requestLyrics(for trackID: String, generation: String? = nil, force: Bool) {
        guard !trackID.isEmpty else { return }
        let requestedGeneration = generation ?? activeGeneration
        let requestID = UUID()
        lyricsCancellation?.cancel()
        let cancellation = SpicyLyricsRequestCancellation()
        lyricsCancellation = cancellation
        lyricsRequestID = requestID
        emit(type: "lyrics", payload: [
            "state": "loading",
            "trackId": trackID,
            "generation": requestedGeneration,
            "force": force
        ])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try SpicyLyricsRepository.shared.rendererPayloadData(
                    for: trackID,
                    forceRefresh: force,
                    shouldContinue: { !cancellation.isCancelled }
                )
                let payload = try JSONSerialization.jsonObject(with: data, options: [])
                DispatchQueue.main.async {
                    guard let self,
                          !self.isDetached,
                          self.lyricsRequestID == requestID,
                          self.activeTrackID == trackID,
                          self.activeGeneration == requestedGeneration else { return }
                    // Lyrics can finish several seconds after the view opened.
                    // Re-anchor immediately before painting them so the first
                    // active word/line never uses the clock from the loading frame.
                    self.publishPlaybackAndTrack(forceTrack: false)
                    self.emit(type: "lyrics", payload: [
                        "state": "ready",
                        "trackId": trackID,
                        "generation": requestedGeneration,
                        "data": payload
                    ])
                    self.revealWatchdog?.invalidate()
                    self.revealWatchdog = nil
                    self.revealRenderer()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self,
                          !self.isDetached,
                          self.lyricsRequestID == requestID,
                          self.activeTrackID == trackID,
                          self.activeGeneration == requestedGeneration else { return }
                    self.emit(type: "lyrics", payload: [
                        "state": "failed",
                        "trackId": trackID,
                        "generation": requestedGeneration,
                        "message": "Lyrics are temporarily unavailable."
                    ])
                    self.revealWatchdog?.invalidate()
                    self.revealWatchdog = nil
                    self.revealRenderer()
                    writeDebugLog("[SpicyRenderer] lyrics failed for \(trackID): \(error)")
                }
            }
        }
    }

    private func emit(type: String, payload: Any) {
        guard let webView, !isDetached else { return }
        let envelope: [String: Any] = ["type": type, "payload": payload]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.SpicyNative && window.SpicyNative.receive(\(json));") { _, error in
            if let error { writeDebugLog("[SpicyRenderer] JavaScript event failed: \(error)") }
        }
    }

    private func sendCommandResult(requestID: String, accepted: Bool) {
        guard !requestID.isEmpty else { return }
        emit(type: "commandResult", payload: [
            "requestId": requestID,
            "generation": activeGeneration,
            "accepted": accepted
        ])
    }

    private func resynchronizeAfterForeground() {
        guard isReady, !isDetached else { return }
        emit(type: "lifecycle", payload: ["state": "resuming"])
        foregroundResyncTimer?.invalidate()
        // The synchronous stateful-player getter is safe to sample immediately.
        // A short second sample covers Spotify completing its own activation
        // transition without ever advancing a hidden JavaScript clock.
        publishPlaybackAndTrack(forceTrack: true, requiresFreshSample: true)
        emit(type: "lifecycle", payload: ["state": "visible"])
        foregroundResyncTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            guard let self, !self.isDetached else { return }
            self.foregroundResyncTimer = nil
            self.publishPlaybackAndTrack(forceTrack: true)
        }
    }

    private func commandMatchesActiveGeneration(_ body: [String: Any]) -> Bool {
        guard let requestedGeneration = body["generation"] as? String,
              !requestedGeneration.isEmpty else {
            return true
        }
        return requestedGeneration == activeGeneration
    }

    private func rendererPreferences() -> [String: Any] {
        let defaults = UserDefaults.standard
        let prefix = "EeveeSpotify.SpicyRenderer."
        return [
            "romanized": defaults.object(forKey: prefix + "romanized") as? Bool ?? false,
            "translations": defaults.object(forKey: prefix + "translations") as? Bool ?? true,
            "dynamicBackground": defaults.object(forKey: prefix + "dynamicBackground") as? Bool ?? true,
            "fontSize": min(126, max(82, defaults.object(forKey: prefix + "fontSize") as? Int ?? 100))
        ]
    }

    private func persistPreference(key: String, value: Any?) -> Bool {
        let defaults = UserDefaults.standard
        let prefix = "EeveeSpotify.SpicyRenderer."
        switch key {
        case "romanized", "translations", "dynamicBackground":
            guard let value = value as? Bool else { return false }
            defaults.set(value, forKey: prefix + key)
        case "fontSize":
            guard let value = value as? NSNumber else { return false }
            defaults.set(min(126, max(82, value.intValue)), forKey: prefix + key)
        default:
            return false
        }
        return true
    }

    private func close() {
        guard let controller else { return }
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true)
        } else if controller.navigationController?.topViewController === controller {
            controller.navigationController?.popViewController(animated: true)
        } else {
            controller.view.window?.rootViewController?.dismiss(animated: true)
        }
    }

    private func revealRenderer() {
        guard let controller, let webView, webView.alpha < 1 else { return }
        controller.view.bringSubviewToFront(webView)

        // If presentation has not started, make the renderer part of the
        // controller's normal transition. If it became ready unusually late,
        // use a very short continuity fade over the still-live native view.
        guard controller.viewIfLoaded?.window != nil,
              !UIAccessibility.isReduceMotionEnabled else {
            webView.alpha = 1
            return
        }
        UIView.animate(
            withDuration: 0.16,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction],
            animations: { webView.alpha = 1 }
        )
    }

    private func fallBackToNative(reason: String) {
        writeDebugLog("[SpicyRenderer] native fallback: \(reason)")
        detach()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fallBackToNative(reason: "navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fallBackToNative(reason: "provisional navigation failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fallBackToNative(reason: "web content process terminated")
    }
}
