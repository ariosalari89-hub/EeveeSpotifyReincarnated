import UIKit

@MainActor
private func removalAlert(in controller: UIViewController) -> UIAlertController? {
    if let result = controller as? UIAlertController { return result }
    if let presented = controller.presentedViewController, let result = removalAlert(in: presented) { return result }
    return controller.children.compactMap { removalAlert(in: $0) }.first
}

@MainActor
private func containsActionLabel(_ title: String, in view: UIView) -> Bool {
    view.accessibilityLabel == title || (view as? UILabel)?.text == title ||
        view.subviews.contains { containsActionLabel(title, in: $0) }
}

@MainActor
private func activateNativeAction(_ title: String, in view: UIView) -> Bool {
    if let control = view as? UIControl, containsActionLabel(title, in: control) {
        control.sendActions(for: .touchUpInside)
        control.sendActions(for: .primaryActionTriggered)
        return true
    }
    if view.accessibilityLabel == title && view.accessibilityActivate() { return true }
    if let list = view as? UITableView,
       let row = list.visibleCells.first(where: { containsActionLabel(title, in: $0) }),
       let path = list.indexPath(for: row),
       list.delegate?.responds(to: #selector(UITableViewDelegate.tableView(_:didSelectRowAt:))) == true {
        list.delegate?.tableView?(list, didSelectRowAt: path)
        return true
    }
    if let list = view as? UICollectionView,
       let row = list.visibleCells.first(where: { containsActionLabel(title, in: $0) }),
       let path = list.indexPath(for: row),
       list.delegate?.responds(to: #selector(UICollectionViewDelegate.collectionView(_:didSelectItemAt:))) == true {
        list.delegate?.collectionView?(list, didSelectItemAt: path)
        return true
    }
    return view.subviews.contains { activateNativeAction(title, in: $0) }
}

@MainActor
extension QAAppDelegate {
    func verifyNativeRemovalConfirmation(navigation: UINavigationController) async throws {
        mark("Reviewing and cancelling native removal of the exact imported copy")
        let list = table(in: navigation.topViewController!.view)!
        let row = cell("local_files_file", label: "Renamed on phone.wav", in: list)!
        let path = list.indexPath(for: row)!
        guard let configuration = list.delegate?.tableView?(list, trailingSwipeActionsConfigurationForRowAt: path),
              let remove = configuration.actions.first(where: { $0.title == "Remove file" }) else {
            throw Failure(description: "an imported row needs a native Remove file action")
        }
        try expect(!configuration.performsFirstActionWithFullSwipe && remove.style == .destructive,
                   "removal must be marked destructive and a full swipe must not commit it")
        let copy = documents.appendingPathComponent("Renamed on phone.wav")
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("Picked song.wav")
        let before = try Data(contentsOf: copy)
        remove.handler(remove, row) { _ in }
        try await waitUntil("Remove file must open a native confirmation before mutating the imported copy") {
            guard let alert = removalAlert(in: navigation) else { return false }
            return alert.title == "Remove Renamed on phone.wav?" && alert.viewIfLoaded?.window != nil && !alert.isBeingPresented
        }
        let alert = removalAlert(in: navigation)!
        try expect(alert.preferredStyle == .alert && alert.actions.map(\.title) == ["Cancel", "Remove file"] &&
                   alert.actions.last?.style == .destructive &&
                   alert.message == "This deletes the copy in Spotify. Originals stored elsewhere are not removed. You can import the file again.",
                   "the native confirmation must identify exact scope, consequence and recovery")
        let reviewed = try Data(contentsOf: copy)
        try expect(reviewed == before, "showing a removal confirmation must not delete or alter its file")
        try await capture("remove-confirmation")
        alert.dismiss(animated: false)
        try await waitUntil("closing the removal confirmation must return to the unchanged file inventory") {
            removalAlert(in: navigation) == nil && cell("local_files_file", label: "Renamed on phone.wav", in: list) != nil
        }
        let cancelled = try Data(contentsOf: copy)
        let preserved = try Data(contentsOf: original)
        try expect(cancelled == before && preserved == before,
                   "cancelling removal must preserve the imported copy and external original byte for byte")
        mark("Confirming removal through the rendered native dialog action")
        remove.handler(remove, row) { _ in }
        try await waitUntil("the second removal confirmation must finish appearing") {
            guard let alert = removalAlert(in: navigation) else { return false }
            return alert.viewIfLoaded?.window != nil && !alert.isBeingPresented
        }
        let confirmed = removalAlert(in: navigation)!
        try expect(activateNativeAction("Remove file", in: confirmed.view),
                   "the native confirmation must expose an activatable public UI control or accessibility action")
        try await waitUntil("confirmed removal must reconcile the authoritative file inventory") {
            removalAlert(in: navigation) == nil && cell("local_files_file", label: "Renamed on phone.wav", in: list) == nil &&
                !FileManager.default.fileExists(atPath: copy.path)
        }
        let originalAfter = try Data(contentsOf: original)
        try expect(originalAfter == before && cell("local_files_file", label: "Evening tone.mp3", in: list) != nil,
                   "confirmed native removal must preserve the external original and other imported songs")
        try await capture("removed")
    }
}
