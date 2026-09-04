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

/// Owns one full-screen renderer and the complete native/WebKit protocol.
/// Track metadata and playback are deliberately sent as one `session` message;
/// a WebKit run-loop turn can therefore never combine one song's artwork or
/// lyrics generation with another song's clock.
final class SpicyLyricsFullscreenHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private static let rendererProtocolVersion = 5
    private static let heartbeatInterval: TimeInterval = 0.25
    private static let maximumWebContentRestarts = 2
    private static let rendererStabilityInterval: TimeInterval = 20
    private static let lyricsUpgradeDelays: [TimeInterval] = [4, 12]

    private weak var controller: UIViewController?
    private var rendererURL: URL?
    private var webView: WKWebView?
    private var heartbeatTimer: Timer?
    private var readyWatchdog: Timer?
    private var revealWatchdog: Timer?
    private var rendererStabilityTimer: Timer?
    private var lyricsUpgradeTimer: Timer?
    private var foregroundTimers = [Timer]()
    private var observers = [NSObjectProtocol]()
    private var isReady = false
    private var isDetached = false
    private var activeTrackID = ""
    private var activeGeneration = ""
    private var lyricsRequestID = UUID()
    private var lyricsCancellation: SpicyLyricsRequestCancellation?
    private var lyricsUpgradeAttempt = 0
    private var webContentRestartCount = 0
    private var isRecoveringRenderer = false

    private let onClose: (() -> Void)?
    private let onReveal: (() -> Void)?

    init(controller: UIViewController, onClose: (() -> Void)? = nil, onReveal: (() -> Void)? = nil) {
        self.controller = controller
        self.onClose = onClose
        self.onReveal = onReveal
        super.init()
    }

    @discardableResult
    func attach() -> Bool {
        guard let pageURL = BundleHelper.shared.resourceURL(
            "index",
            withExtension: "html",
            subdirectory: "SpicyLyricsRenderer"
        ) else {
            writeDebugLog("[SpicyRenderer] renderer bundle is missing; keeping native lyrics")
            return false
        }

        rendererURL = pageURL
        registerObservers()
        installRenderer(pageURL: pageURL)
        writeDebugLog("[SpicyRenderer] attached protocol=5")
        return true
    }

    func detach() {
        guard !isDetached else { return }
        isDetached = true
        invalidateTimers()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        cancelLyricsRequest()
        cancelLyricsUpgrade(resetAttempts: true)
        destroyWebView()
    }

    private func registerObservers() {
        observers = [
            NotificationCenter.default.addObserver(
                forName: .spicyLyricsPlaybackStateDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.publishSession(reason: "observer")
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, !self.isDetached else { return }
                SpicyLyricsPlaybackBridge.shared.suspendPlaybackClock()
                self.emit(type: "lifecycle", payload: ["state": "hidden"])
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.resynchronizeAfterForeground()
            }
        ]
    }

    private func installRenderer(pageURL: URL) {
        guard let controller, !isDetached else { return }
        isRecoveringRenderer = false
        rendererStabilityTimer?.invalidate()
        rendererStabilityTimer = nil
        destroyWebView()
        isReady = false

        let contentController = WKUserContentController()
        contentController.add(self, name: "eevee")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true

        let renderer = WKWebView(frame: .zero, configuration: configuration)
        renderer.navigationDelegate = self
        renderer.translatesAutoresizingMaskIntoConstraints = false
        renderer.isOpaque = false
        renderer.backgroundColor = .black
        renderer.scrollView.backgroundColor = .black
        renderer.scrollView.contentInsetAdjustmentBehavior = .never
        renderer.scrollView.isScrollEnabled = false
        renderer.allowsLinkPreview = false
        renderer.accessibilityLabel = "Spicy Lyrics"
        renderer.alpha = 0

        controller.view.addSubview(renderer)
        NSLayoutConstraint.activate([
            renderer.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            renderer.topAnchor.constraint(equalTo: controller.view.topAnchor),
            renderer.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor)
        ])
        controller.view.bringSubviewToFront(renderer)
        webView = renderer
        renderer.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())

        readyWatchdog?.invalidate()
        readyWatchdog = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            guard let self, !self.isReady else { return }
            self.recoverOrFallBack(reason: "renderer did not become ready")
        }
    }

    private func destroyWebView() {
        guard let webView else { return }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "eevee")
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
        self.webView = nil
    }

    private func invalidateTimers() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        readyWatchdog?.invalidate()
        readyWatchdog = nil
        revealWatchdog?.invalidate()
        revealWatchdog = nil
        rendererStabilityTimer?.invalidate()
        rendererStabilityTimer = nil
        foregroundTimers.forEach { $0.invalidate() }
        foregroundTimers.removeAll()
    }

    private func cancelLyricsRequest() {
        lyricsCancellation?.cancel()
        lyricsCancellation = nil
        lyricsRequestID = UUID()
    }

    private func cancelLyricsUpgrade(resetAttempts: Bool) {
        lyricsUpgradeTimer?.invalidate()
        lyricsUpgradeTimer = nil
        if resetAttempts { lyricsUpgradeAttempt = 0 }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "eevee", !isDetached,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        let requestID = body["requestId"] as? String ?? ""
        switch type {
        case "ready":
            let version = (body["rendererProtocolVersion"] as? NSNumber)?.intValue ?? -1
            guard version == Self.rendererProtocolVersion else {
                fallBackToNative(reason: "renderer protocol mismatch: \(version)")
                return
            }
            rendererDidBecomeReady()
        case "close":
            sendCommandResult(requestID: requestID, command: type, accepted: true)
            close()
        case "seek":
            guard commandMatchesActiveGeneration(body),
                  let number = body["positionMs"] as? NSNumber,
                  number.doubleValue.isFinite else {
                sendCommandResult(requestID: requestID, command: type, accepted: false)
                return
            }
            let accepted = SpicyLyricsPlaybackBridge.shared.perform(
                command: type,
                value: max(0, number.doubleValue / 1000)
            )
            sendCommandResult(requestID: requestID, command: type, accepted: accepted)
            publishSession(reason: "seek-command")
        case "togglePlay", "play", "pause", "next", "previous", "toggleShuffle", "cycleRepeat":
            guard commandMatchesActiveGeneration(body) else {
                sendCommandResult(requestID: requestID, command: type, accepted: false)
                return
            }
            let accepted = SpicyLyricsPlaybackBridge.shared.perform(command: type)
            sendCommandResult(requestID: requestID, command: type, accepted: accepted)
            publishSession(reason: "\(type)-command")
        case "resync":
            resynchronizeAfterForeground()
            sendCommandResult(requestID: requestID, command: type, accepted: true)
        case "retryLyrics":
            guard !activeTrackID.isEmpty else {
                sendCommandResult(requestID: requestID, command: type, accepted: false)
                return
            }
            cancelLyricsUpgrade(resetAttempts: true)
            requestLyrics(for: activeTrackID, generation: activeGeneration, force: true)
            sendCommandResult(requestID: requestID, command: type, accepted: true)
        case "setPreference":
            let key = body["key"] as? String ?? ""
            let accepted = persistPreference(key: key, value: body["value"])
            sendCommandResult(requestID: requestID, command: type, accepted: accepted)
        case "diagnostic":
            recordDiagnostic(body)
        default:
            sendCommandResult(requestID: requestID, command: type, accepted: false)
        }
    }

    private func rendererDidBecomeReady() {
        guard !isReady, !isDetached else { return }
        isReady = true
        readyWatchdog?.invalidate()
        readyWatchdog = nil
        writeDebugLog("[SpicyRenderer] ready protocol=5")

        if webContentRestartCount > 0 {
            rendererStabilityTimer = Timer.scheduledTimer(
                withTimeInterval: Self.rendererStabilityInterval,
                repeats: false
            ) { [weak self] _ in
                guard let self, self.isReady, !self.isDetached else { return }
                self.webContentRestartCount = 0
                self.rendererStabilityTimer = nil
                writeDebugLog("[SpicyRenderer] WebKit stability window passed")
            }
            if let rendererStabilityTimer {
                RunLoop.main.add(rendererStabilityTimer, forMode: .common)
            }
        }

        emit(type: "bootstrap", payload: [
            "platform": "ios",
            "reduceMotion": UIAccessibility.isReduceMotionEnabled,
            "boldText": UIAccessibility.isBoldTextEnabled,
            "preferences": rendererPreferences()
        ])
        publishSession(reason: "ready", forceLyrics: true)

        revealWatchdog?.invalidate()
        revealWatchdog = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.revealRenderer()
        }
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: Self.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            self?.publishSession(reason: "heartbeat")
        }
        if let heartbeatTimer { RunLoop.main.add(heartbeatTimer, forMode: .common) }
    }

    @discardableResult
    private func publishSession(reason: String, forceLyrics: Bool = false) -> Bool {
        guard isReady, !isDetached,
              let payload = SpicyLyricsPlaybackBridge.shared.sessionPayload(),
              let trackID = payload["trackId"] as? String,
              !trackID.isEmpty else { return false }

        let generation = payload["generation"] as? String ?? ""
        let changed = trackID != activeTrackID
            || (!generation.isEmpty && generation != activeGeneration)
        if changed { cancelLyricsUpgrade(resetAttempts: true) }
        activeTrackID = trackID
        activeGeneration = generation
        emit(type: "session", payload: payload)

        if changed || forceLyrics {
            requestLyrics(for: trackID, generation: generation, force: false)
            writeDebugLog(
                "[SpicyRenderer] session reason=\(reason) generation=\(generation) track=\(trackID)"
            )
        }
        return true
    }

    private func requestLyrics(
        for trackID: String,
        generation: String,
        force: Bool,
        showLoading: Bool = true
    ) {
        guard !trackID.isEmpty, !generation.isEmpty else { return }
        let requestID = UUID()
        cancelLyricsRequest()
        let cancellation = SpicyLyricsRequestCancellation()
        lyricsCancellation = cancellation
        lyricsRequestID = requestID
        if showLoading {
            emit(type: "lyrics", payload: [
                "state": "loading",
                "trackId": trackID,
                "generation": generation,
                "force": force
            ])
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try SpicyLyricsRepository.shared.rendererPayloadData(
                    for: trackID,
                    forceRefresh: force,
                    shouldContinue: { !cancellation.isCancelled }
                )
                let lyrics = try JSONSerialization.jsonObject(with: data, options: [])
                DispatchQueue.main.async {
                    guard let self,
                          !self.isDetached,
                          self.lyricsRequestID == requestID,
                          self.activeTrackID == trackID,
                          self.activeGeneration == generation else { return }
                    self.publishSession(reason: "lyrics-ready")
                    self.emit(type: "lyrics", payload: [
                        "state": "ready",
                        "trackId": trackID,
                        "generation": generation,
                        "data": lyrics
                    ])
                    let lyricsType = (lyrics as? [String: Any])?["Type"] as? String ?? ""
                    if lyricsType.caseInsensitiveCompare("Syllable") == .orderedSame {
                        self.cancelLyricsUpgrade(resetAttempts: false)
                    } else {
                        self.scheduleLyricsUpgrade(for: trackID, generation: generation)
                    }
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
                          self.activeGeneration == generation else { return }
                    if showLoading {
                        self.emit(type: "lyrics", payload: [
                            "state": "failed",
                            "trackId": trackID,
                            "generation": generation,
                            "message": "Lyrics are temporarily unavailable."
                        ])
                        self.revealWatchdog?.invalidate()
                        self.revealWatchdog = nil
                        self.revealRenderer()
                    } else {
                        self.scheduleLyricsUpgrade(for: trackID, generation: generation)
                    }
                    writeDebugLog("[SpicyRenderer] lyrics failed track=\(trackID) error=\(error)")
                }
            }
        }
    }

    private func scheduleLyricsUpgrade(for trackID: String, generation: String) {
        guard lyricsUpgradeAttempt < Self.lyricsUpgradeDelays.count,
              trackID == activeTrackID,
              generation == activeGeneration,
              !isDetached else { return }
        let delay = Self.lyricsUpgradeDelays[lyricsUpgradeAttempt]
        lyricsUpgradeAttempt += 1
        cancelLyricsUpgrade(resetAttempts: false)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) {
            [weak self] timer in
            guard let self else { return }
            self.lyricsUpgradeTimer = nil
            guard !self.isDetached,
                  self.activeTrackID == trackID,
                  self.activeGeneration == generation else { return }
            writeDebugLog(
                "[SpicyRenderer] checking for timed-lyrics upgrade "
                + "attempt=\(self.lyricsUpgradeAttempt) track=\(trackID)"
            )
            self.requestLyrics(
                for: trackID,
                generation: generation,
                force: true,
                showLoading: false
            )
            timer.invalidate()
        }
        lyricsUpgradeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func emit(type: String, payload: Any) {
        guard let webView, !isDetached else { return }
        let envelope: [String: Any] = ["type": type, "payload": payload]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.SpicyNative && window.SpicyNative.receive(\(json));") {
            _, error in
            if let error {
                writeDebugLog("[SpicyRenderer] JavaScript event failed type=\(type): \(error)")
            }
        }
    }

    private func sendCommandResult(requestID: String, command: String, accepted: Bool) {
        guard !requestID.isEmpty else { return }
        emit(type: "commandResult", payload: [
            "requestId": requestID,
            "command": command,
            "generation": activeGeneration,
            "accepted": accepted
        ])
    }

    private func resynchronizeAfterForeground() {
        guard isReady, !isDetached else { return }
        foregroundTimers.forEach { $0.invalidate() }
        foregroundTimers.removeAll()
        SpicyLyricsPlaybackBridge.shared.resumeAwaitingObservation()
        emit(type: "lifecycle", payload: ["state": "resuming"])

        if publishSession(reason: "foreground-immediate") {
            emit(type: "lifecycle", payload: ["state": "visible"])
        }
        for delay in [0.12, 0.45] {
            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] timer in
                guard let self, !self.isDetached else { return }
                _ = self.publishSession(reason: "foreground-followup")
                self.emit(type: "lifecycle", payload: ["state": "visible"])
                self.foregroundTimers.removeAll { $0 === timer }
            }
            foregroundTimers.append(timer)
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func commandMatchesActiveGeneration(_ body: [String: Any]) -> Bool {
        guard let generation = body["generation"] as? String,
              !generation.isEmpty else { return false }
        return generation == activeGeneration
    }

    private func rendererPreferences() -> [String: Any] {
        let defaults = UserDefaults.standard
        let prefix = "EeveeSpotify.SpicyRenderer."
        return [
            "romanized": defaults.object(forKey: prefix + "romanized") as? Bool ?? false,
            "translations": defaults.object(forKey: prefix + "translations") as? Bool ?? true,
            "dynamicBackground": defaults.object(forKey: prefix + "dynamicBackground") as? Bool ?? true,
            "fontSize": min(126, max(82, defaults.object(forKey: prefix + "fontSize") as? Int ?? 100)),
            "playbackOffset": min(
                5000,
                max(-5000, defaults.object(forKey: prefix + "playbackOffset") as? Int ?? 0)
            )
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
        case "playbackOffset":
            guard let value = value as? NSNumber else { return false }
            defaults.set(min(5000, max(-5000, value.intValue)), forKey: prefix + key)
        default:
            return false
        }
        return true
    }

    private func recordDiagnostic(_ body: [String: Any]) {
        let kind = body["kind"] as? String ?? "unknown"
        let trackID = body["trackId"] as? String ?? ""
        let lyricsType = body["lyricsType"] as? String ?? "unknown"
        let generation = body["generation"] as? String ?? ""
        let lineCount = (body["lineCount"] as? NSNumber)?.intValue ?? -1
        let timedLineCount = (body["timedLineCount"] as? NSNumber)?.intValue ?? -1
        let firstStart = (body["firstStartMs"] as? NSNumber)?.doubleValue ?? -1
        let lastEnd = (body["lastEndMs"] as? NSNumber)?.doubleValue ?? -1
        writeDebugLog(
            "[SpicyRenderer] diagnostic=\(kind) generation=\(generation) track=\(trackID) "
            + "type=\(lyricsType) lines=\(lineCount)/\(timedLineCount) "
            + "range=\(firstStart)..\(lastEnd)"
        )
    }

    private func close() {
        if let onClose { onClose(); return }
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
        onReveal?()
        controller.view.bringSubviewToFront(webView)
        guard controller.viewIfLoaded?.window != nil,
              !UIAccessibility.isReduceMotionEnabled else {
            webView.alpha = 1
            return
        }
        UIView.animate(
            withDuration: 0.14,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction],
            animations: { webView.alpha = 1 }
        )
    }

    private func recoverOrFallBack(reason: String) {
        guard !isRecoveringRenderer else { return }
        guard webContentRestartCount < Self.maximumWebContentRestarts,
              let rendererURL,
              !isDetached else {
            fallBackToNative(reason: reason)
            return
        }
        isRecoveringRenderer = true
        webContentRestartCount += 1
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        readyWatchdog?.invalidate()
        readyWatchdog = nil
        revealWatchdog?.invalidate()
        revealWatchdog = nil
        rendererStabilityTimer?.invalidate()
        rendererStabilityTimer = nil
        cancelLyricsRequest()
        cancelLyricsUpgrade(resetAttempts: false)
        isReady = false
        destroyWebView()
        writeDebugLog(
            "[SpicyRenderer] recreating WebKit attempt=\(webContentRestartCount) reason=\(reason)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.installRenderer(pageURL: rendererURL)
        }
    }

    private func fallBackToNative(reason: String) {
        writeDebugLog("[SpicyRenderer] native fallback: \(reason)")
        detach()
        onClose?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        recoverOrFallBack(reason: "navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView else { return }
        recoverOrFallBack(reason: "provisional navigation failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        recoverOrFallBack(reason: "web content process terminated")
    }
}
