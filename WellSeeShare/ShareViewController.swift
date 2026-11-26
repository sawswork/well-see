import UIKit
import ImageIO
import UniformTypeIdentifiers

/// 共有シートで「ウィルシー」を選んだときに動く画面。
/// 受け取ったもの（URL・文字・画像）を置き場に書き、「保存しました」と出してすぐ閉じる。
/// 入力は何も求めない。
final class ShareViewController: UIViewController {
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let icon = UIImageView()
    private let label = UILabel()
    private var started = false

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

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -22),
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
        if success {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        UIView.animate(withDuration: 0.18) { self.card.alpha = 1 }
        try? await Task.sleep(nanoseconds: success ? 900_000_000 : 1_600_000_000)
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
