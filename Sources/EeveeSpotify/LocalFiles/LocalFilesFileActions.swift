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

    private func showRename(_ file: LocalAudioFile) {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let editor = LocalAudioRenameController(file: file, model: model)
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .pageSheet
        navigation.isModalInPresentation = true
        present(navigation, animated: true)
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
