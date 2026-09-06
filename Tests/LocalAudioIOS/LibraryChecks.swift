import UIKit

@MainActor
func alert(in controller: UIViewController) -> UIAlertController? {
    if let result = controller as? UIAlertController { return result }
    if let presented = controller.presentedViewController, let result = alert(in: presented) { return result }
    return controller.children.compactMap { alert(in: $0) }.first
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
            guard let actions = alert(in: navigation) else { return false }
            return actions.viewIfLoaded?.window != nil && !actions.isBeingPresented
        }
        let actions = alert(in: navigation)!
        try expect(actions.title == "Picked song.wav" && actions.actions.map(\.title) == ["Rename file", "Remove file", "Cancel"],
                   "file actions must identify the exact imported filename and offer rename, remove and cancel")
        try await capture("file-actions")
        actions.dismiss(animated: false)
        try await waitUntil("file-action cancellation must return to the unchanged inventory") {
            alert(in: navigation) == nil && cell("local_files_file", label: "Picked song.wav", in: list) != nil
        }
    }
}
