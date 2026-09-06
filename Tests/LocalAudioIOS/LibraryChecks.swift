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
        try await waitUntil("the recreated settings host must finish mounting its native table") {
            guard let host = navigation.topViewController, let list = table(in: host.view) else { return false }
            return list.window != nil
        }
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
        try await waitUntil("Rename file must open a persistent native filename editor, not an alert") {
            guard let editor = filenameEditor(in: navigation) else { return false }
            return editor.title == "Rename file" && filenameInput(in: editor.view)?.text == "Picked song" &&
                editor.viewIfLoaded?.window != nil && !editor.isBeingPresented
        }
        let editor = filenameEditor(in: navigation)!
        let field = filenameInput(in: editor.view)!
        try expect(field.accessibilityLabel == "Filename" &&
                   editor.navigationItem.leftBarButtonItem?.title == "Cancel" &&
                   editor.navigationItem.rightBarButtonItem?.title == "Save" &&
                   editor.navigationController?.isModalInPresentation == true,
                   "the filename editor needs a named input and explicit save/cancel actions")
        try await verifySelectionDoesNotSave(editor: editor, field: field, navigation: navigation)
        try await capture("rename-editing")
        try tapFilenameAction("local_files_save", editor: editor)
        // Native callers can submit a button twice before the next run-loop turn.
        // The disabled action must neither rename twice nor reopen a stale editor.
        let save = editor.navigationItem.rightBarButtonItem!
        if let action = save.action { UIApplication.shared.sendAction(action, to: save.target, from: save, for: nil) }
        try await waitUntil("submitting the filename must show the authoritative renamed copy") {
            filenameEditor(in: navigation) == nil && cell("local_files_file", label: "Renamed on phone.wav", in: list) != nil &&
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

    func verifyNativeRenameRecovery(navigation: UINavigationController) async throws {
        mark("Checking filename collision recovery without overwriting another imported song")
        let list = table(in: navigation.topViewController!.view)!
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("Existing name.wav")
        try makeAudio(at: other)
        try tap("local_files_import", in: list)
        try await waitUntil("the collision fixture must use the actual audio picker") {
            guard let picker = picker(in: navigation) else { return false }
            return picker.viewIfLoaded?.window != nil && !picker.isBeingPresented
        }
        let selection = picker(in: navigation)!
        selection.delegate?.documentPicker?(selection, didPickDocumentsAt: [other])
        try await waitUntil("the second file must appear before testing its occupied name") {
            picker(in: navigation) == nil && cell("local_files_file", label: "Existing name.wav", in: list) != nil
        }
        let original = documents.appendingPathComponent("Renamed on phone.wav")
        let occupied = documents.appendingPathComponent("Existing name.wav")
        let originalBytes = try Data(contentsOf: original), occupiedBytes = try Data(contentsOf: occupied)
        let row = cell("local_files_file", label: "Renamed on phone.wav", in: list)!
        let path = list.indexPath(for: row)!
        let configuration = list.delegate!.tableView!(list, trailingSwipeActionsConfigurationForRowAt: path)!
        let rename = configuration.actions.first { $0.title == "Rename file" }!
        rename.handler(rename, row) { _ in }
        try await waitUntil("the existing file must open its filename editor") {
            guard let editor = filenameEditor(in: navigation) else { return false }
            return filenameInput(in: editor.view)?.text == "Renamed on phone" && !editor.isBeingPresented
        }
        let editor = filenameEditor(in: navigation)!
        let field = filenameInput(in: editor.view)!
        field.text = "Existing name"
        try tapFilenameAction("local_files_save", editor: editor)
        try await waitUntil("a filename collision must preserve the proposed value with a corrective error") {
            return filenameEditor(in: navigation) === editor && field.text == "Existing name" &&
                editor.navigationItem.rightBarButtonItem?.isEnabled == true &&
                filenameError(in: editor.view)?.text == "A file with that name already exists. Choose another name."
        }
        let afterOriginal = try Data(contentsOf: original), afterOccupied = try Data(contentsOf: occupied)
        try expect(afterOriginal == originalBytes && afterOccupied == occupiedBytes,
                   "a failed native filename edit must preserve both files byte for byte")
        try await capture("rename-collision")
        field.text = "invalid/name"
        try tapFilenameAction("local_files_save", editor: editor)
        try await waitUntil("invalid names must stay in the same editor with an inline error") {
            filenameEditor(in: navigation) === editor && field.text == "invalid/name" &&
                editor.navigationItem.rightBarButtonItem?.isEnabled == true &&
                filenameError(in: editor.view)?.text == "local_files_invalid_name".localized
        }
        field.text = "Renamed on phone"
        try tapFilenameAction("local_files_save", editor: editor)
        var readySamples = 0
        try await waitUntil("correcting a filename error must close the editor and retain the selected copy") {
            let row = cell("local_files_file", label: "Renamed on phone.wav", in: list)
            let ready = filenameEditor(in: navigation) == nil && !editor.isBeingDismissed &&
                row?.isUserInteractionEnabled == true && row?.accessibilityTraits.contains(.notEnabled) == false
            readySamples = ready ? readySamples + 1 : 0
            return readySamples >= 2
        }
        let current = cell("local_files_file", label: "Renamed on phone.wav", in: list)!
        let currentPath = list.indexPath(for: current)!
        let actions = list.delegate!.tableView!(list, trailingSwipeActionsConfigurationForRowAt: currentPath)!
        let cancelRename = actions.actions.first { $0.title == "Rename file" }!
        cancelRename.handler(cancelRename, current) { _ in }
        try await waitUntil("cancel scenario must open the real filename editor") {
            filenameEditor(in: navigation)?.viewIfLoaded?.window != nil
        }
        let cancelled = filenameEditor(in: navigation)!
        filenameInput(in: cancelled.view)!.text = "This must not be saved"
        try tapFilenameAction("local_files_cancel", editor: cancelled)
        try await waitUntil("explicit Cancel must close without changing the selected file") {
            filenameEditor(in: navigation) == nil && cell("local_files_file", label: "Renamed on phone.wav", in: list) != nil
        }
        let bytesAfterCancel = try Data(contentsOf: original)
        try expect(bytesAfterCancel == originalBytes &&
                   !FileManager.default.fileExists(atPath: documents.appendingPathComponent("This must not be saved.wav").path),
                   "cancelling a draft must preserve the filename and audio")
    }
}
