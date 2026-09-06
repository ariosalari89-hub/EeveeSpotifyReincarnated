import UIKit

// Exercise system text input and visible native target/actions. No shipping
// controller implementation or model internals are replaced by the harness.
@MainActor
func filenameEditor(in controller: UIViewController) -> UIViewController? {
    if controller.navigationItem.rightBarButtonItem?.accessibilityIdentifier == "local_files_save" { return controller }
    if let presented = controller.presentedViewController, let result = filenameEditor(in: presented) { return result }
    return controller.children.compactMap { filenameEditor(in: $0) }.first
}

@MainActor
func filenameInput(in view: UIView) -> UITextView? {
    if let field = view as? UITextView, field.accessibilityIdentifier == "local_files_filename" { return field }
    return view.subviews.compactMap { filenameInput(in: $0) }.first
}

@MainActor
func filenameError(in view: UIView) -> UILabel? {
    if let label = view as? UILabel, label.accessibilityIdentifier == "local_files_rename_error" { return label }
    return view.subviews.compactMap { filenameError(in: $0) }.first
}

@MainActor
func tapFilenameAction(_ identifier: String, editor: UIViewController) throws {
    let items = [editor.navigationItem.leftBarButtonItem, editor.navigationItem.rightBarButtonItem].compactMap { $0 }
    guard let item = items.first(where: { $0.accessibilityIdentifier == identifier }), item.isEnabled,
          let action = item.action,
          UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil) else {
        throw Failure(description: "the visible native filename action is unavailable: " + identifier)
    }
}

@MainActor
extension QAAppDelegate {
    func verifyFilenameLayout(navigation: UINavigationController, list: UITableView,
                              variant: String, category: UIContentSizeCategory) async throws {
        let path = IndexPath(row: 0, section: list.numberOfSections - 1)
        list.scrollToRow(at: path, at: .top, animated: false)
        let row = list.cellForRow(at: path)!
        let configuration = list.delegate!.tableView!(list, trailingSwipeActionsConfigurationForRowAt: path)!
        let rename = configuration.actions.first { $0.title == "Rename file" }!
        rename.handler(rename, row) { _ in }
        try await waitUntil("the filename layout fixture must finish presenting and focus its input") {
            guard let editor = filenameEditor(in: navigation), let field = filenameInput(in: editor.view) else { return false }
            return editor.navigationController?.isBeingPresented == false && field.isFirstResponder
        }
        let editor = filenameEditor(in: navigation)!, field = filenameInput(in: filenameEditor(in: navigation)!.view)!
        editor.view.layoutIfNeeded()
        mark("Filename layout \(variant): category=\(field.traitCollection.preferredContentSizeCategory.rawValue), font=\(field.font?.pointSize ?? 0), input=\(field.bounds.size), editor=\(editor.view.bounds.size)")
        try await capture("rename-" + variant + "-initial")
        try expect(field.traitCollection.preferredContentSizeCategory == category && field.isEditable && field.isSelectable &&
                   field.isScrollEnabled && field.bounds.width >= 180 && field.bounds.width <= editor.view.bounds.width &&
                   field.bounds.height >= 144 && editor.navigationItem.leftBarButtonItem?.isEnabled == true &&
                   editor.navigationItem.rightBarButtonItem?.isEnabled == true,
                   "the native filename input must remain selectable, scrollable and reachable in " + variant)
        if category == .accessibilityExtraExtraExtraLarge {
            try expect((field.font?.pointSize ?? 0) > 30 && field.bounds.height > 200,
                       "the filename editor must actually enlarge its text and input for accessibility")
        }
        field.selectAll(nil)
        field.insertText("A long filename — a selectable section — another selectable section — final section 音楽")
        field.selectAll(nil)
        try await capture("rename-" + variant)
        try tapFilenameAction("local_files_cancel", editor: editor)
        try await waitUntil("cancelling the layout draft must dismiss only its editor") { filenameEditor(in: navigation) == nil }
    }

    func verifySelectionDoesNotSave(editor: UIViewController, field: UITextView, navigation: UINavigationController) async throws {
        mark("Selecting, cutting, pasting and deleting a long filename without dismissing its editor")
        let source = documents.appendingPathComponent("Picked song.wav")
        let original = try Data(contentsOf: source)
        field.becomeFirstResponder()
        field.selectAll(nil)
        field.insertText("A long filename — delete this entire middle section — final section 音楽")
        let start = field.position(from: field.beginningOfDocument, offset: 18)!
        let end = field.position(from: field.beginningOfDocument, offset: 53)!
        field.selectedTextRange = field.textRange(from: start, to: end)
        let selected = field.text(in: field.selectedTextRange!)!
        try expect(selected.count > 20, "the regression must really select a large part of the filename")
        field.cut(nil)
        try expect(!field.text.contains(selected), "native Cut must remove the selected range from the draft")
        try expect(UIPasteboard.general.string == selected, "native Cut must place the actual selected range on the system pasteboard")
        field.paste(nil)
        // UIKit paste uses item providers and incorporates their result on the
        // main run loop. Await its visible completion, not the return from
        // paste(_:). The expected text/editor identity are unchanged.
        try await waitUntil("native Paste must restore the selected draft text", seconds: 2) {
            field.text.contains(selected) && filenameEditor(in: navigation) === editor
        }
        field.selectAll(nil)
        field.deleteBackward()
        try expect(field.text.isEmpty, "native selected deletion must be editable without closing an empty draft")
        field.insertText("Renamed on phone")
        field.insertText("\n")
        field.endEditing(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let unchanged = try Data(contentsOf: source)
        mark("Filename input outcome: text=\(field.text.debugDescription), sameEditor=\(filenameEditor(in: navigation) === editor), visible=\(editor.view.window != nil), bytesUnchanged=\(unchanged == original)")
        try expect(filenameEditor(in: navigation) === editor && editor.view.window != nil &&
                   field.text == "Renamed on phone" && unchanged == original &&
                   !FileManager.default.fileExists(atPath: documents.appendingPathComponent("Renamed on phone.wav").path),
                   "selection, Cut/Paste, deletion, Return and editing end must not dismiss or commit the filename editor")
    }
}
