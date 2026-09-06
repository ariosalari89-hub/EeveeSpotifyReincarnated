import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine

struct LocalFilesSettingsView: UIViewControllerRepresentable {
    var model: LocalFilesImportModel = .shared

    func makeUIViewController(context: Context) -> LocalFilesSettingsController {
        LocalFilesSettingsController(model: model)
    }

    func updateUIViewController(_ controller: LocalFilesSettingsController, context: Context) {}
}

final class LocalFilesSettingsController: UITableViewController, UIDocumentPickerDelegate {
    private let model: LocalFilesImportModel
    private var state: LocalFilesImportModel.State
    private var observation: AnyCancellable?
    private weak var activePicker: UIDocumentPickerViewController?
    private let accent = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 30 / 255, green: 215 / 255, blue: 96 / 255, alpha: 1)
            : UIColor(red: 16 / 255, green: 112 / 255, blue: 49 / 255, alpha: 1)
    }

    init(model: LocalFilesImportModel) {
        self.model = model
        state = model.state
        super.init(style: .insetGrouped)
        title = "local_files_title".localized
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.tintColor = accent
        observation = model.$state.sink { [weak self] state in
            guard let self = self else { return }
            self.state = state
            self.tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        state.isImporting ? 2 : (state.results.isEmpty ? 1 : 3)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 2 ? state.results.count : 1
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "local_files_enable_note".localized : nil
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 2 ? "local_files_results".localized : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = makeCell("local_files_import".localized, identifier: "local_files_import")
            cell.textLabel?.textColor = state.isImporting ? .secondaryLabel : accent
            cell.accessibilityTraits = state.isImporting ? [.button, .notEnabled] : .button
            cell.isUserInteractionEnabled = !state.isImporting
            cell.imageView?.image = UIImage(systemName: "square.and.arrow.down")
            return cell
        }
        if indexPath.section == 1 {
            if state.isImporting {
                let title = String(format: "local_files_progress".localized,
                                   min(state.progress.completedFiles + 1, state.progress.totalFiles), state.progress.totalFiles)
                return makeCell(title, detail: state.progress.currentName, identifier: "local_files_progress")
            }
            let copied = state.results.filter { if case .copied = $0.outcome { return true }; return false }.count
            let present = state.results.filter { if case .alreadyPresent = $0.outcome { return true }; return false }.count
            let summary = String(format: "local_files_summary".localized, copied, present, state.results.count - copied - present)
            return makeCell("local_files_finished".localized, detail: summary, identifier: "local_files_summary")
        }
        let result = state.results[indexPath.row]
        return makeCell(result.sourceName, detail: status(for: result), identifier: "local_files_result")
    }

    private func makeCell(_ title: String, detail: String? = nil, identifier: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = detail
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.accessibilityIdentifier = identifier
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = title
        cell.accessibilityValue = detail
        cell.accessibilityTraits = .staticText
        cell.selectionStyle = .none
        return cell
    }

    private func status(for result: LocalAudioImportResult) -> String {
        switch result.outcome {
        case .copied(let url):
            return url.lastPathComponent == result.sourceName ? "local_files_copied".localized
                : String(format: "local_files_copied_as".localized, url.lastPathComponent)
        case .alreadyPresent: return "local_files_present".localized
        case .failed(let failure): return failure.rawValue.localized
        case .cancelled: return "local_files_cancelled".localized
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0, !state.isImporting, presentedViewController == nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        activePicker = picker
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard controller === activePicker else { return }
        activePicker = nil
        controller.dismiss(animated: true)
        model.importSelection(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard controller === activePicker else { return }
        activePicker = nil
        controller.dismiss(animated: true)
    }
}
