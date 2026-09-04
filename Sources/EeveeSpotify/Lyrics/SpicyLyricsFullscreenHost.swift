import Foundation
import UIKit
import WebKit

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
    private weak var controller: UIViewController?
    private var webView: WKWebView?
    private var playbackTimer: Timer?
    private var readyWatchdog: Timer?
    private var isReady = false
    private var isDetached = false
    private var activeTrackID = ""
    private var lyricsRequestID = UUID()

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
            rendererDidBecomeReady()
        case "close":
            sendCommandResult(requestID: requestID, accepted: true)
            close()
        case "seek":
            let milliseconds = (body["positionMs"] as? NSNumber)?.doubleValue ?? 0
            let accepted = SpicyLyricsPlaybackBridge.shared.perform(command: "seek", value: milliseconds / 1000)
            sendCommandResult(requestID: requestID, accepted: accepted)
        case "togglePlay", "play", "pause", "next", "previous":
            let accepted = SpicyLyricsPlaybackBridge.shared.perform(command: type)
            sendCommandResult(requestID: requestID, accepted: accepted)
        case "retryLyrics":
            requestLyrics(for: activeTrackID, force: true)
        case "setPreference":
            let key = body["key"] as? String ?? ""
            let accepted = persistPreference(key: key, value: body["value"])
            sendCommandResult(requestID: requestID, accepted: accepted)
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
            "rendererVersion": "1.0.0",
            "platform": "ios",
            "reduceMotion": UIAccessibility.isReduceMotionEnabled,
            "boldText": UIAccessibility.isBoldTextEnabled,
            "safeFallback": true,
            "preferences": rendererPreferences()
        ])

        publishPlaybackAndTrack(forceTrack: true)
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.publishPlaybackAndTrack(forceTrack: false)
        }
        RunLoop.main.add(playbackTimer!, forMode: .common)
    }

    private func publishPlaybackAndTrack(forceTrack: Bool) {
        guard isReady, !isDetached else { return }
        let playback = SpicyLyricsPlaybackBridge.shared.playbackPayload()
        emit(type: "playback", payload: playback)

        let bridgeID = playback["trackId"] as? String ?? ""
        let currentID = bridgeID.isEmpty
            ? (SpicyLyricsPlaybackBridge.shared.currentTrackID() ?? "")
            : bridgeID
        guard !currentID.isEmpty else { return }

        if forceTrack || currentID != activeTrackID {
            activeTrackID = currentID
            let track = SpicyLyricsPlaybackBridge.shared.trackPayload()
            emit(type: "track", payload: track)
            requestLyrics(for: currentID, force: false)
        }
    }

    private func requestLyrics(for trackID: String, force: Bool) {
        guard !trackID.isEmpty else { return }
        let requestID = UUID()
        lyricsRequestID = requestID
        emit(type: "lyrics", payload: ["state": "loading", "trackId": trackID, "force": force])

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try SpicyLyricsRepository.shared.rendererPayloadData(for: trackID)
                let payload = try JSONSerialization.jsonObject(with: data, options: [])
                DispatchQueue.main.async {
                    guard let self,
                          !self.isDetached,
                          self.lyricsRequestID == requestID,
                          self.activeTrackID == trackID else { return }
                    self.emit(type: "lyrics", payload: [
                        "state": "ready",
                        "trackId": trackID,
                        "data": payload
                    ])
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self,
                          !self.isDetached,
                          self.lyricsRequestID == requestID,
                          self.activeTrackID == trackID else { return }
                    self.emit(type: "lyrics", payload: [
                        "state": "failed",
                        "trackId": trackID,
                        "message": "Lyrics are temporarily unavailable."
                    ])
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
        emit(type: "commandResult", payload: ["requestId": requestID, "accepted": accepted])
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
