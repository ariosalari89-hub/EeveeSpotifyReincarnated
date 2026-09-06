import UIKit

extension LocalFilesSettingsController {
    func showFileActions(_ file: LocalAudioFile, from source: UIView) {
        let actions = UIAlertController(title: file.name, message: nil, preferredStyle: .actionSheet)
        actions.addAction(UIAlertAction(title: "local_files_rename".localized, style: .default) { [weak self, weak actions] _ in
            guard let self = self else { return }
            if let actions = actions, actions.presentingViewController != nil {
                actions.dismiss(animated: true) { [weak self] in self?.showRename(file) }
            } else { self.showRename(file) }
        })
        actions.addAction(UIAlertAction(title: "local_files_remove".localized, style: .destructive) { [weak self, weak actions] _ in
            guard let self = self else { return }
            if let actions = actions, actions.presentingViewController != nil {
                actions.dismiss(animated: true) { [weak self] in self?.showRemove(file) }
            } else { self.showRemove(file) }
        })
        actions.addAction(UIAlertAction(title: "local_files_cancel".localized, style: .cancel))
        actions.popoverPresentationController?.sourceView = source
        actions.popoverPresentationController?.sourceRect = source.bounds
        present(actions, animated: true)
    }

    func swipeActions(for file: LocalAudioFile) -> UISwipeActionsConfiguration {
        let rename = UIContextualAction(style: .normal, title: "local_files_rename".localized) { [weak self] _, _, done in
            done(false)
            self?.showRename(file)
        }
        let remove = UIContextualAction(style: .destructive, title: "local_files_remove".localized) { [weak self] _, _, done in
            done(false)
            self?.showRemove(file)
        }
        let configuration = UISwipeActionsConfiguration(actions: [remove, rename])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    private func showRename(_ file: LocalAudioFile, proposed: String? = nil, failure: LocalAudioLibraryFailure? = nil) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let editor = UIAlertController(title: "local_files_rename".localized,
                                       message: (failure?.rawValue ?? "local_files_rename_note").localized,
                                       preferredStyle: .alert)
        editor.addTextField { [weak self, weak editor] field in
            field.text = proposed ?? file.fileURL.deletingPathExtension().lastPathComponent
            field.accessibilityIdentifier = "local_files_filename"
            field.accessibilityLabel = "local_files_filename".localized
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
            field.enablesReturnKeyAutomatically = true
            field.addAction(UIAction { [weak self, weak editor] _ in
                guard let editor = editor else { return }
                self?.saveRename(file, from: editor)
            }, for: .editingDidEndOnExit)
        }
        editor.addAction(UIAlertAction(title: "local_files_cancel".localized, style: .cancel))
        editor.addAction(UIAlertAction(title: "local_files_save".localized, style: .default) { [weak self, weak editor] _ in
            guard let editor = editor else { return }
            self?.saveRename(file, from: editor)
        })
        present(editor, animated: true)
    }

    private func saveRename(_ file: LocalAudioFile, from editor: UIAlertController) {
        // UIKit may submit the default action as well as the field's Return
        // event. One editor can commit only once, including during dismissal.
        guard let save = editor.actions.last, save.isEnabled else { return }
        save.isEnabled = false
        let proposed = editor.textFields?.first?.text ?? ""
        // Dismissal precedes the filesystem operation, so an immediate failure
        // can reopen the editor with the user's proposed value intact.
        let model = self.model
        let apply = { [weak self] in
            model.rename(file, toStem: proposed) { [weak self] result in
                if case .failure(let failure) = result { self?.showRename(file, proposed: proposed, failure: failure) }
            }
        }
        if editor.presentingViewController != nil { editor.dismiss(animated: true, completion: apply) }
        else { apply() }
    }

    private func showRemove(_ file: LocalAudioFile) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let confirmation = UIAlertController(title: String(format: "local_files_remove_title".localized, file.name),
                                             message: "local_files_remove_note".localized, preferredStyle: .alert)
        let cancel = UIAlertAction(title: "local_files_cancel".localized, style: .cancel)
        confirmation.addAction(cancel)
        confirmation.preferredAction = cancel
        confirmation.addAction(UIAlertAction(title: "local_files_remove".localized, style: .destructive) { [weak self, weak confirmation] action in
            guard let self = self, let confirmation = confirmation, action.isEnabled else { return }
            action.isEnabled = false
            let model = self.model
            let apply = { [weak self] in
                model.remove(file) { [weak self] result in
                    guard case .failure(let failure) = result, let self = self,
                          self.viewIfLoaded?.window != nil, self.presentedViewController == nil else { return }
                    let error = UIAlertController(title: "local_files_remove".localized,
                                                  message: failure.rawValue.localized, preferredStyle: .alert)
                    error.addAction(UIAlertAction(title: "local_files_ok".localized, style: .default))
                    self.present(error, animated: true)
                }
            }
            if confirmation.presentingViewController != nil { confirmation.dismiss(animated: true, completion: apply) }
            else { apply() }
        })
        present(confirmation, animated: true)
    }
}
