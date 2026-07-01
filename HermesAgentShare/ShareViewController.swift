import UIKit
import UniformTypeIdentifiers

/// Share Extension: send URLs, text, and images to Mac hub as Hermes memos.
final class ShareViewController: UIViewController {
    private let noteField = UITextField()
    private let statusLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var isSaving = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 320, height: 180)

        let titleLabel = UILabel()
        titleLabel.text = "Hermesに保存"
        titleLabel.font = .boldSystemFont(ofSize: 17)

        noteField.placeholder = "メモ（任意）"
        noteField.borderStyle = .roundedRect
        noteField.font = .systemFont(ofSize: 15)

        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.text = "Webページ・テキスト・写真を備忘録として送ります"

        saveButton.setTitle("保存", for: .normal)
        saveButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        spinner.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, noteField, statusLabel, saveButton, spinner])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
        ])
    }

    @objc private func saveTapped() {
        guard !isSaving else { return }
        isSaving = true
        saveButton.isEnabled = false
        spinner.startAnimating()
        statusLabel.text = "送信中…"

        Task { @MainActor in
            defer {
                isSaving = false
                saveButton.isEnabled = true
                spinner.stopAnimating()
            }
            do {
                let payload = try await loadPayload()
                let note = noteField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await HermesIngestClient.ingest(
                    kind: payload.kind,
                    url: payload.url,
                    title: payload.title,
                    text: payload.text,
                    note: note,
                    images: payload.images
                )
                statusLabel.text = "コレクションに保存しました"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.extensionContext?.completeRequest(returningItems: nil)
                }
            } catch {
                statusLabel.text = HermesIngestClient.friendlyNetworkError(error)
            }
        }
    }

    private struct Payload {
        var kind: String
        var url: String?
        var title: String?
        var text: String?
        var images: [Data] = []
    }

    private func loadPayload() async throws -> Payload {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            throw HermesIngestClient.IngestError.badResponse
        }
        var url: String?
        var title: String?
        var textParts: [String] = []
        var images: [Data] = []

        for item in items {
            guard let providers = item.attachments else { continue }
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let u = try await loadURL(from: provider) {
                        url = u.absoluteString
                        title = item.attributedTitle?.string ?? item.attributedContentText?.string
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let t = try await loadText(from: provider), !t.isEmpty {
                        textParts.append(t)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let data = try await loadImage(from: provider), images.count < 3 {
                        images.append(data)
                    }
                }
            }
        }

        if let url, !url.isEmpty {
            return Payload(
                kind: "url", url: url, title: title,
                text: textParts.joined(separator: "\n")
            )
        }
        if !images.isEmpty {
            return Payload(kind: "image", text: textParts.joined(separator: "\n"), images: images)
        }
        let text = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw HermesIngestClient.IngestError.badResponse
        }
        return Payload(kind: "text", text: text)
    }

    private func loadURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, error in
                if let error { cont.resume(throwing: error); return }
                if let u = item as? URL { cont.resume(returning: u); return }
                if let s = item as? String, let u = URL(string: s) { cont.resume(returning: u); return }
                cont.resume(returning: nil)
            }
        }
    }

    private func loadText(from provider: NSItemProvider) async throws -> String? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: item as? String)
            }
        }
    }

    private func loadImage(from provider: NSItemProvider) async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, error in
                if let error { cont.resume(throwing: error); return }
                if let img = item as? UIImage,
                   let data = HermesIngestClient.jpegData(from: img) {
                    cont.resume(returning: data)
                    return
                }
                if let data = item as? Data,
                   let img = UIImage(data: data),
                   let jpeg = HermesIngestClient.jpegData(from: img) {
                    cont.resume(returning: jpeg)
                    return
                }
                cont.resume(returning: nil)
            }
        }
    }
}
