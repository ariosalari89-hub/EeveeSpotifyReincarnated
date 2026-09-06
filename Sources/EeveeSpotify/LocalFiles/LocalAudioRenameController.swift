import UIKit

/// A filename draft is UI state, not an alert action. Only the explicit Save
/// target can submit it; selection and first-responder changes never dismiss it.
final class LocalAudioRenameController: UIViewController, UITextViewDelegate {
    private let file: LocalAudioFile
    private let model: LocalFilesImportModel
    private let scroll = UIScrollView()
    private let filename = UITextView()
    private let errorLabel = UILabel()
    private var inputHeight: NSLayoutConstraint!
    private var keyboardObserver: NSObjectProtocol?
    private var saving = false
    private var focused = false

    init(file: LocalAudioFile, model: LocalFilesImportModel) {
        self.file = file
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = "local_files_rename".localized
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer = keyboardObserver { NotificationCenter.default.removeObserver(observer) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "local_files_cancel".localized,
            style: .plain, target: self, action: #selector(cancel))
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "local_files_cancel"
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "local_files_save".localized,
            style: .done, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "local_files_save"

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .none
        view.addSubview(scroll)
        let heading = label("local_files_filename".localized, style: .headline)
        let suffix = file.fileURL.pathExtension
        let extensionLabel = label(suffix.isEmpty ? "" : "." + suffix, style: .body)
        extensionLabel.accessibilityIdentifier = "local_files_extension"
        extensionLabel.setContentHuggingPriority(.required, for: .horizontal)
        let headingRow = UIStackView(arrangedSubviews: [heading, extensionLabel])
        headingRow.spacing = 12

        filename.text = file.fileURL.deletingPathExtension().lastPathComponent
        filename.accessibilityIdentifier = "local_files_filename"
        filename.accessibilityLabel = "local_files_filename".localized
        filename.font = .preferredFont(forTextStyle: .body)
        filename.adjustsFontForContentSizeCategory = true
        filename.textColor = .label
        filename.backgroundColor = .secondarySystemGroupedBackground
        filename.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
        filename.autocapitalizationType = .none
        filename.autocorrectionType = .no
        filename.spellCheckingType = .no
        filename.smartQuotesType = .no
        filename.smartDashesType = .no
        filename.returnKeyType = .done
        filename.layer.cornerRadius = 12
        filename.layer.borderWidth = 1 / UIScreen.main.scale
        filename.delegate = self
        inputHeight = filename.heightAnchor.constraint(equalToConstant: 144)
        inputHeight.isActive = true

        errorLabel.font = .preferredFont(forTextStyle: .body)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = .label
        errorLabel.numberOfLines = 0
        errorLabel.accessibilityIdentifier = "local_files_rename_error"
        errorLabel.isHidden = true
        let note = label("local_files_rename_note".localized, style: .footnote)
        let content = UIStackView(arrangedSubviews: [headingRow, filename, errorLabel, note])
        content.axis = .vertical
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
        updateAppearance()
        keyboardObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil, queue: .main) { [weak self] notification in
                self?.keyboardChanged(notification)
            }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !focused else { return }
        focused = true
        filename.becomeFirstResponder()
        filename.selectedRange = NSRange(location: 0, length: (filename.text as NSString).length)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded { updateAppearance() }
    }

    private func updateAppearance() {
        filename.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        inputHeight.constant = max(144, UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: traitCollection).lineHeight * 4 + 28)
    }

    private func label(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let result = UILabel()
        result.text = text
        result.font = .preferredFont(forTextStyle: style)
        result.adjustsFontForContentSizeCategory = true
        result.textColor = .label
        result.numberOfLines = 0
        return result
    }

    private func keyboardChanged(_ notification: Notification) {
        guard let screenFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let frame = view.convert(screenFrame, from: nil)
        let overlap = max(0, view.bounds.maxY - frame.minY - view.safeAreaInsets.bottom)
        scroll.contentInset.bottom = overlap
        scroll.verticalScrollIndicatorInsets.bottom = overlap
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            // Done ends keyboard editing only. It is deliberately not Save.
            textView.resignFirstResponder()
            return false
        }
        return !saving
    }

    func textViewDidChange(_ textView: UITextView) { errorLabel.isHidden = true }

    @objc private func cancel() {
        guard !saving else { return }
        dismiss(animated: true)
    }

    @objc private func save() {
        guard !saving, filename.markedTextRange == nil else { return }
        saving = true
        filename.isEditable = false
        navigationItem.leftBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.title = "local_files_renaming".localized
        errorLabel.isHidden = true
        model.rename(file, toStem: filename.text) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                // Keep saving true until dismissal finishes: duplicate actions
                // cannot submit the old filesystem identity again.
                self.dismiss(animated: true)
            case .failure(let failure):
                self.saving = false
                self.filename.isEditable = true
                self.navigationItem.leftBarButtonItem?.isEnabled = true
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                self.navigationItem.rightBarButtonItem?.title = "local_files_save".localized
                self.errorLabel.text = failure.rawValue.localized
                self.errorLabel.isHidden = false
                UIAccessibility.post(notification: .announcement, argument: self.errorLabel.text)
            }
        }
    }
}
