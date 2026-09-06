import UIKit
import SwiftUI
import AVFoundation

// The fixture uses the shipping English resource through the app-bundle boundary.
extension String {
    var localized: String { Bundle.main.localizedString(forKey: self, value: nil, table: nil) }
}

struct Failure: Error, CustomStringConvertible { let description: String }

@MainActor
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw Failure(description: message) }
}

@MainActor
func waitUntil(_ message: String, seconds: Double = 8, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw Failure(description: message)
}

@MainActor
func table(in view: UIView) -> UITableView? {
    if let table = view as? UITableView { return table }
    return view.subviews.compactMap { table(in: $0) }.first
}

@MainActor
func picker(in controller: UIViewController) -> UIDocumentPickerViewController? {
    if let picker = controller as? UIDocumentPickerViewController { return picker }
    if let presented = controller.presentedViewController, let picker = picker(in: presented) { return picker }
    return controller.children.compactMap { picker(in: $0) }.first
}

@MainActor
func cell(_ identifier: String, label: String? = nil, in table: UITableView) -> UITableViewCell? {
    table.layoutIfNeeded()
    for section in 0..<table.numberOfSections {
        for row in 0..<table.numberOfRows(inSection: section) {
            let path = IndexPath(row: row, section: section)
            table.scrollToRow(at: path, at: .middle, animated: false)
            table.layoutIfNeeded()
            if let cell = table.cellForRow(at: path), cell.accessibilityIdentifier == identifier,
               label == nil || cell.accessibilityLabel == label { return cell }
        }
    }
    return nil
}

@MainActor
func tap(_ identifier: String, in table: UITableView) throws {
    if let visible = cell(identifier, in: table), let path = table.indexPath(for: visible) {
        table.delegate?.tableView?(table, didSelectRowAt: path)
        return
    }
    throw Failure(description: "visible native action not found: " + identifier)
}

func makeAudio(at url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
    buffer.frameLength = 4_410
    for index in 0..<4_410 { buffer.floatChannelData![0][index] = 0.25 }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

/// A real coordinated writer at the filesystem boundary holds one selected
/// fixture while the native UI is exercised. No importer internals are mocked.
final class CoordinatedInputHold {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var holding = false

    var isHolding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return holding
    }

    init(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { _ in
                lock.lock()
                holding = true
                lock.unlock()
                _ = releaseSignal.wait(timeout: .now() + 30)
                lock.lock()
                holding = false
                lock.unlock()
            }
        }
    }

    func release() { releaseSignal.signal() }
}

@MainActor
final class QAAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var openedRoutes: [URL] = []
    var routeAccepted = true
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let host = makeHost()
        let navigation = UINavigationController(rootViewController: host)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
        Task { await run(navigation: navigation) }
        return true
    }

    func makeHost() -> UIViewController {
        let host = UIHostingController(rootView: LocalFilesSettingsView(openURL: { [weak self] url, completion in
            self?.openedRoutes.append(url)
            completion(self?.routeAccepted ?? false)
        }))
        host.title = "local_files_title".localized
        return host
    }

    func run(navigation: UINavigationController) async {
        do {
            mark("Waiting for native settings page")
            try await waitUntil("the real local-files page did not render") { table(in: navigation.view) != nil }
            let list = table(in: navigation.view)!
            mark("Opening native audio picker")
            try tap("local_files_import", in: list)
            try await waitUntil("Import audio files must present the actual system document picker") { picker(in: navigation) != nil }
            let systemPicker = picker(in: navigation)!
            try await waitUntil("the native picker presentation did not finish") {
                systemPicker.viewIfLoaded?.window != nil && !systemPicker.isBeingPresented
            }
            try expect(systemPicker.allowsMultipleSelection && systemPicker.documentPickerMode == .import,
                       "the native picker must select multiple copied files, not edit originals in place")
            mark("Submitting selected audio through the native picker delegate")
            let original = FileManager.default.temporaryDirectory.appendingPathComponent("Picked song.wav")
            try makeAudio(at: original)
            let originalBytes = try Data(contentsOf: original)
            systemPicker.delegate?.documentPicker?(systemPicker, didPickDocumentsAt: [original])
            try await waitUntil("picker completion must copy the selected song and show its Copied result") {
                picker(in: navigation) == nil && cell("local_files_result", in: list)?.accessibilityValue == "Copied"
            }
            let copied = documents.appendingPathComponent("Picked song.wav")
            let copiedBytes = try Data(contentsOf: copied)
            let preservedBytes = try Data(contentsOf: original)
            let playerInput = try AVAudioFile(forReading: copied)
            try expect(copiedBytes == originalBytes && preservedBytes == originalBytes && playerInput.length == 4_410,
                       "the visible Copied receipt must correspond to real playable output with the source preserved")
            try await capture("imported")
            try tap("local_files_open", in: list)
            try expect(openedRoutes.map(\.absoluteString) == ["spotify:local-files"],
                       "Open Local Files must request Spotify's native collection through the no-effect route boundary")
            try await stopAcrossNavigation(navigation: navigation)
            try await cancelAndRetry(navigation: navigation)
            try await verifyRouteFallback(navigation: navigation)
            try await verifyLayouts(returningTo: navigation)
            mark("Native import output verified")
            try "PASS: native import action presents the multi-audio copy picker\nPASS: real picker completion produces playable output and a visible Copied receipt\nPASS: Open Local Files requests the native collection route\nPASS: stop across native page navigation retains completed songs and cancels waiting work\nPASS: cancelling the picker preserves results and a mixed retry reports real WAV/MP3/AAC copies, duplicate and failed audio\nPASS: an unavailable native route presents a manual collection path\nPASS: native light, dark, narrow, landscape, large-text and RTL layout/accessibility checks\nPASS\n"
                .write(to: documents.appendingPathComponent("local-audio-ui-result.txt"), atomically: true, encoding: .utf8)
        } catch {
            try? await capture("failure")
            let list = table(in: navigation.view)
            var visible: [String] = []
            if let list = list {
                for section in 0..<list.numberOfSections {
                    for row in 0..<list.numberOfRows(inSection: section) {
                        let path = IndexPath(row: row, section: section)
                        list.scrollToRow(at: path, at: .middle, animated: false)
                        list.layoutIfNeeded()
                        if let cell = list.cellForRow(at: path) {
                            visible.append("\(cell.accessibilityIdentifier ?? "no id"): \(cell.accessibilityLabel ?? "no label") | \(cell.accessibilityValue ?? "no value")")
                        }
                    }
                }
            }
            let outputs = ((try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []).filter { $0.hasSuffix(".wav") }
            try? "FAIL: \(error)\nVISIBLE: \(visible)\nOUTPUTS: \(outputs)\n".write(to: documents.appendingPathComponent("local-audio-ui-result.txt"), atomically: true, encoding: .utf8)
        }
    }

    func stopAcrossNavigation(navigation: UINavigationController) async throws {
        mark("Testing stop across native page navigation with a coordinated input")
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("Completed before stop.wav")
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent("Waiting to copy.wav")
        try makeAudio(at: first)
        try makeAudio(at: blocked)
        let blockedBytes = try Data(contentsOf: blocked)
        let hold = CoordinatedInputHold(blocked)
        defer { hold.release() }
        try await waitUntil("the external fixture writer did not acquire its file") { hold.isHolding }
        try tap("local_files_import", in: table(in: navigation.view)!)
        try await waitUntil("the next native audio picker did not present") {
            guard let picker = picker(in: navigation) else { return false }
            return picker.viewIfLoaded?.window != nil && !picker.isBeingPresented
        }
        let selection = picker(in: navigation)!
        selection.delegate?.documentPicker?(selection, didPickDocumentsAt: [first, blocked])
        try await waitUntil("the first song did not complete while the second input was in use") {
            picker(in: navigation) == nil &&
                FileManager.default.fileExists(atPath: self.documents.appendingPathComponent(first.lastPathComponent).path) &&
                cell("local_files_progress", in: table(in: navigation.view)!)?.accessibilityLabel == "Importing 2 of 2"
        }
        navigation.setViewControllers([UIViewController()], animated: false)
        navigation.setViewControllers([makeHost()], animated: false)
        try await waitUntil("returning to settings lost the active import") {
            // A navigation container can still contain the outgoing host's
            // table during UIKit teardown. Observe only the new top page.
            guard let host = navigation.topViewController,
                  let list = table(in: host.view), list.window != nil else { return false }
            return cell("local_files_progress", in: list)?.accessibilityLabel == "Importing 2 of 2"
        }
        let returnedList = table(in: navigation.topViewController!.view)!
        try expect(cell("local_files_import", in: returnedList)?.isUserInteractionEnabled == false,
                   "a running import must not allow a second selection to replace it")
        try tap("local_files_stop", in: returnedList)
        try expect(cell("local_files_stop", in: returnedList)?.accessibilityTraits.contains(.notEnabled) == true,
                   "Stop must acknowledge its request while the external read is still waiting")
        mark("Stop acknowledged; releasing the coordinated writer")
        hold.release()
        try await waitUntil("stopping must preserve the completed song and report the uncommitted selection") {
            returnedList.window != nil &&
                cell("local_files_result", label: first.lastPathComponent, in: returnedList)?.accessibilityValue == "Copied" &&
                cell("local_files_result", label: blocked.lastPathComponent, in: returnedList)?.accessibilityValue == "Not copied — stopped"
        }
        let kept = try AVAudioFile(forReading: documents.appendingPathComponent(first.lastPathComponent))
        let originalAfter = try Data(contentsOf: blocked)
        try expect(kept.length == 4_410 && originalAfter == blockedBytes &&
                   !FileManager.default.fileExists(atPath: documents.appendingPathComponent(blocked.lastPathComponent).path),
                   "the native cancellation receipt must agree with actual files and preserved originals")
        try await capture("stopped")
    }

    func capture(_ name: String) async throws {
        // Capture the real owned UIKit view without waiting on simctl's display
        // service. The runner takes a separate compositor screenshot after all
        // behavior checks finish; the real system picker capture is retained
        // from its first successful integration run.
        guard let window = window else { throw Failure(description: "no native window to render") }
        window.layoutIfNeeded()
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard rendered, let png = image.pngData() else { throw Failure(description: "native view rendering failed") }
        try png.write(to: documents.appendingPathComponent("local-audio-\(name).png"))
        mark("UIKit view captured: " + name)
    }

    func mark(_ message: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + message
        try? line.write(to: documents.appendingPathComponent("local-audio-ui-progress.txt"), atomically: true, encoding: .utf8)
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(QAAppDelegate.self))
