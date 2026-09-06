import UIKit
import SwiftUI

@MainActor
private func fileAlert(in controller: UIViewController) -> UIAlertController? {
    if let result = controller as? UIAlertController { return result }
    if let presented = controller.presentedViewController, let result = fileAlert(in: presented) { return result }
    return controller.children.compactMap { fileAlert(in: $0) }.first
}

@MainActor
extension QAAppDelegate {
    func verifyImportedFileEntry(navigation: UINavigationController) async throws {
        mark("Opening the imported-file actions from the native inventory")
        let list = table(in: navigation.topViewController!.view)!
        try await waitUntil("the completed import must appear in the persistent imported-file inventory") {
            cell("local_files_file", label: "Picked song.wav", in: list) != nil
        }
        let row = cell("local_files_file", label: "Picked song.wav", in: list)!
        let path = list.indexPath(for: row)!
        list.delegate?.tableView?(list, didSelectRowAt: path)
        try await waitUntil("selecting an imported file must open its native actions") {
            guard let actions = fileAlert(in: navigation) else { return false }
            return actions.viewIfLoaded?.window != nil && !actions.isBeingPresented
        }
        let actions = fileAlert(in: navigation)!
        try expect(actions.title == "Picked song.wav" && actions.actions.map(\.title) == ["Rename file", "Remove file", "Cancel"],
                   "file actions must identify the exact imported filename and offer rename, remove and cancel")
        try await capture("file-actions")
        actions.dismiss(animated: false)
        try await waitUntil("file-action cancellation must return to the unchanged inventory") {
            fileAlert(in: navigation) == nil && cell("local_files_file", label: "Picked song.wav", in: list) != nil
        }
    }

    func verifyNativeFilenameRename(navigation: UINavigationController) async throws {
        mark("Renaming a file through its native swipe action and filename editor")
        let list = table(in: navigation.topViewController!.view)!
        try await waitUntil("the imported file must be available after native page re-entry") {
            cell("local_files_file", label: "Picked song.wav", in: list) != nil
        }
        let row = cell("local_files_file", label: "Picked song.wav", in: list)!
        let path = list.indexPath(for: row)!
        guard let configuration = list.delegate?.tableView?(list, trailingSwipeActionsConfigurationForRowAt: path),
              let rename = configuration.actions.first(where: { $0.title == "Rename file" }) else {
            throw Failure(description: "an imported row needs a native Rename file action")
        }
        try expect(!configuration.performsFirstActionWithFullSwipe,
                   "a full swipe must not bypass review or commit a file mutation")
        rename.handler(rename, row) { _ in }
        try await waitUntil("Rename file must open an editable native filename field") {
            guard let editor = fileAlert(in: navigation) else { return false }
            return editor.title == "Rename file" && editor.textFields?.first?.text == "Picked song" &&
                editor.viewIfLoaded?.window != nil && !editor.isBeingPresented
        }
        let editor = fileAlert(in: navigation)!
        let field = editor.textFields!.first!
        try expect(field.accessibilityLabel == "Filename" && editor.actions.map(\.title) == ["Cancel", "Save"],
                   "the filename editor needs a named input and explicit save/cancel actions")
        field.text = "Renamed on phone"
        try await capture("rename-editing")
        field.sendActions(for: .editingDidEndOnExit)
        try await waitUntil("submitting the filename must show the authoritative renamed copy") {
            fileAlert(in: navigation) == nil && cell("local_files_file", label: "Renamed on phone.wav", in: list) != nil &&
                cell("local_files_file", label: "Picked song.wav", in: list) == nil
        }
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("Picked song.wav")
        let before = try Data(contentsOf: original)
        let after = try Data(contentsOf: documents.appendingPathComponent("Renamed on phone.wav"))
        try expect(before == after, "the filename editor must preserve the audio bytes and external original")
        let freshModel = LocalFilesImportModel(directory: documents)
        let reopened = UIHostingController(rootView: LocalFilesSettingsView(model: freshModel))
        reopened.title = "Local Files"
        navigation.setViewControllers([reopened], animated: false)
        try await waitUntil("a newly created model and native page must recover the renamed inventory") {
            guard let list = table(in: reopened.view) else { return false }
            return list.window != nil && cell("local_files_file", label: "Renamed on phone.wav", in: list) != nil
        }
        try await capture("rename-reopened")
    }
}
