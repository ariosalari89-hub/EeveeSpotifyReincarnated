import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LocalFilesSettingsView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> LocalFilesSettingsController {
        LocalFilesSettingsController()
    }

    func updateUIViewController(_ controller: LocalFilesSettingsController, context: Context) {}
}

final class LocalFilesSettingsController: UITableViewController, UIDocumentPickerDelegate {
    init() {
        super.init(style: .insetGrouped)
        title = "local_files_title".localized
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = "local_files_import".localized
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.accessibilityIdentifier = "local_files_import"
        cell.accessibilityTraits = .button
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
