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
func cell(_ identifier: String, in table: UITableView) -> UITableViewCell? {
    table.layoutIfNeeded()
    for section in 0..<table.numberOfSections {
        for row in 0..<table.numberOfRows(inSection: section) {
            let path = IndexPath(row: row, section: section)
            table.scrollToRow(at: path, at: .middle, animated: false)
            table.layoutIfNeeded()
            if let cell = table.cellForRow(at: path), cell.accessibilityIdentifier == identifier { return cell }
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

@MainActor
final class QAAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let host = UIHostingController(rootView: LocalFilesSettingsView())
        host.title = "local_files_title".localized
        let navigation = UINavigationController(rootViewController: host)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
        Task { await run(navigation: navigation) }
        return true
    }

    func run(navigation: UINavigationController) async {
        do {
            try await waitUntil("the real local-files page did not render") { table(in: navigation.view) != nil }
            let list = table(in: navigation.view)!
            try tap("local_files_import", in: list)
            try await waitUntil("Import audio files must present the actual system document picker") { picker(in: navigation) != nil }
            let systemPicker = picker(in: navigation)!
            try await waitUntil("the native picker presentation did not finish") {
                systemPicker.viewIfLoaded?.window != nil && !systemPicker.isBeingPresented
            }
            try expect(systemPicker.allowsMultipleSelection && systemPicker.documentPickerMode == .import,
                       "the native picker must select multiple copied files, not edit originals in place")
            try await capture("picker")
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
            try "PASS: native import action presents the multi-audio copy picker\nPASS: real picker completion produces playable output and a visible Copied receipt\nPASS\n"
                .write(to: documents.appendingPathComponent("local-audio-ui-result.txt"), atomically: true, encoding: .utf8)
        } catch {
            try? "FAIL: \(error)\n".write(to: documents.appendingPathComponent("local-audio-ui-result.txt"), atomically: true, encoding: .utf8)
        }
    }

    func capture(_ name: String) async throws {
        try name.write(to: documents.appendingPathComponent("local-audio-capture.txt"), atomically: true, encoding: .utf8)
        try await waitUntil("native screenshot was not captured", seconds: 40) {
            FileManager.default.fileExists(atPath: self.documents.appendingPathComponent("capture-\(name).done").path)
        }
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(QAAppDelegate.self))
