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
        field.paste(nil)
        try expect(field.text.contains(selected), "native Paste must restore the selected draft text")
        field.selectAll(nil)
        field.deleteBackward()
        try expect(field.text.isEmpty, "native selected deletion must be editable without closing an empty draft")
        field.insertText("Renamed on phone")
        field.insertText("\n")
        field.endEditing(true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let unchanged = try Data(contentsOf: source)
        try expect(filenameEditor(in: navigation) === editor && editor.view.window != nil &&
                   field.text == "Renamed on phone" && unchanged == original &&
                   !FileManager.default.fileExists(atPath: documents.appendingPathComponent("Renamed on phone.wav").path),
                   "selection, Cut/Paste, deletion, Return and editing end must not dismiss or commit the filename editor")
    }
}
