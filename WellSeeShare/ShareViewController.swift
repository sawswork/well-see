import UIKit
import ImageIO
import UniformTypeIdentifiers

/// 共有シートで「ウィルシー」を選んだときに動く画面。
/// 受け取ったもの（URL・文字・画像）を置き場に書き、「保存しました」と出してすぐ閉じる。
/// 入力は何も求めない。出ているあいだに「ほかの人に送る」を押すと、同じものをそのまま人に送れる。
final class ShareViewController: UIViewController {
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let icon = UIImageView()
    private let label = UILabel()
    private let shareButton = UIButton(type: .system)
    private var started = false
    /// ほかの人に送るもの（保存したものと同じ）。
    private var shareItems: [Any] = []
    private var closing: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.alpha = 0
        view.addSubview(card)

        icon.contentMode = .scaleAspectFit
        icon.tintColor = .label
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.tinted()
        config.image = UIImage(systemName: "square.and.arrow.up")
        config.title = "ほかの人に送る"
        config.imagePadding = 6
        config.cornerStyle = .capsule
        config.buttonSize = .medium
        shareButton.configuration = config
        shareButton.tintColor = .label
        shareButton.isHidden = true
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [icon, label, shareButton])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.setCustomSpacing(16, after: label)
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -14),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await save() }
    }

    private func save() async {
        var url: String?
        var text: String?
        var image: Data?
        var gps: (latitude: Double, longitude: Double)?

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            if text == nil, let t = item.attributedContentText?.string, !t.isEmpty {
                text = t
            }
            for provider in item.attachments ?? [] {
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let u = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) as? URL,
                       let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                        url = u.absoluteString
                    }
                } else if image == nil, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let loaded = await loadImage(provider) {
                        image = loaded.data
                        gps = loaded.gps
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let t = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) as? String,
                       !t.isEmpty, text == nil {
                        text = t
                    }
                }
            }
        }

        // 文字の中に URL があれば、それをリンクとして扱う。
        if url == nil, let t = text, let found = firstLink(in: t) {
            url = found
        }

        guard url != nil || text != nil || image != nil else {
            await finish(success: false)
            return
        }
        let entry = InboxItem(id: UUID(), date: Date(), url: url, text: text, imageFile: nil,
                              latitude: gps?.latitude, longitude: gps?.longitude)
        let ok = Inbox.write(entry, imageData: image)
        if let url, let link = URL(string: url) {
            shareItems = [link]
        } else if let image, let picture = UIImage(data: image) {
            shareItems = [picture]
        } else if let text {
            shareItems = [text]
        }
        await finish(success: ok)
    }

    private func loadImage(_ provider: NSItemProvider) async -> (data: Data, gps: (latitude: Double, longitude: Double)?)? {
        guard let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) else {
            return nil
        }
        var source: CGImageSource?
        if let fileURL = loaded as? URL {
            source = CGImageSourceCreateWithURL(fileURL as CFURL, nil)
        } else if let data = loaded as? Data {
            source = CGImageSourceCreateWithData(data as CFData, nil)
        } else if let uiImage = loaded as? UIImage, let data = uiImage.jpegData(compressionQuality: 0.9) {
            source = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let source, let jpeg = ImageTools.jpeg(from: source, maxPixel: 1600) else { return nil }
        return (jpeg, ImageTools.gps(from: source))
    }

    private func firstLink(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let u = match.url, let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return u.absoluteString
            }
        }
        return nil
    }

    private func finish(success: Bool) async {
        icon.image = UIImage(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        label.text = success ? "保存しました" : "保存できませんでした"
        shareButton.isHidden = !success || shareItems.isEmpty
        if success {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        UIView.animate(withDuration: 0.18) { self.card.alpha = 1 }
        // ボタンを押せるだけの間をあけてから閉じる。押されたら閉じるのをやめる。
        let wait: UInt64 = !success ? 1_600_000_000 : (shareButton.isHidden ? 900_000_000 : 2_200_000_000)
        closing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            if Task.isCancelled { return }
            self?.close(success: success)
        }
    }

    /// 保存したものを、そのままほかの人に送る（iOS の共有シートを開く）。
    @objc private func shareTapped() {
        closing?.cancel()
        let sheet = UIActivityViewController(activityItems: shareItems, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = shareButton
        sheet.popoverPresentationController?.sourceRect = shareButton.bounds
        sheet.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.close(success: true)
        }
        present(sheet, animated: true)
    }

    private func close(success: Bool) {
        UIView.animate(withDuration: 0.15, animations: { self.card.alpha = 0 }) { _ in
            if success {
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            } else {
                let error = NSError(domain: "WellSeeShare", code: 1)
                self.extensionContext?.cancelRequest(withError: error)
            }
        }
    }
}
