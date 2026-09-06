import UIKit

extension LocalFilesSettingsController {
    func showFileActions(_ file: LocalAudioFile, from source: UIView) {
        let actions = UIAlertController(title: file.name, message: nil, preferredStyle: .actionSheet)
        actions.addAction(UIAlertAction(title: "local_files_rename".localized, style: .default))
        actions.addAction(UIAlertAction(title: "local_files_remove".localized, style: .destructive))
        actions.addAction(UIAlertAction(title: "local_files_cancel".localized, style: .cancel))
        actions.popoverPresentationController?.sourceView = source
        actions.popoverPresentationController?.sourceRect = source.bounds
        present(actions, animated: true)
    }
}
