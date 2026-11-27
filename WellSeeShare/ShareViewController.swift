import UIKit
import ImageIO
import UniformTypeIdentifiers

/// 共有シートで「ウィルシー」を選んだときに動く画面。
/// 受け取ったもの（URL・文字・画像）を置き場に書き、「保存しました」と出す。
/// 何もしなければ数秒で閉じる。カードに触れると閉じるのを待ち、メモを書いたり、
/// 同じものをほかの人に送ったりできる。カードの外を押すか「完了」で閉じる。
final class ShareViewController: UIViewController, UITextFieldDelegate {
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let icon = UIImageView()
    private let label = UILabel()
    private let memoField = UITextField()
    private let shareButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let extras = UIStackView()
    private var started = false
    private var savedID: UUID?
    private var succeeded = false
    private var closed = false
    /// ほかの人に送るもの（保存したものと同じ）。
    private var shareItems: [Any] = []
    private var closing: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        // カードの外を押したら閉じる。
        let outside = UITapGestureRecognizer(target: self, action: #selector(outsideTapped(_:)))
        outside.cancelsTouchesInView = false
        view.addGestureRecognizer(outside)

        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.alpha = 0
        view.addSubview(card)

        // カードに触れたら、自動で閉じるのをやめる。
        let hold = UITapGestureRecognizer(target: self, action: #selector(cardTouched))
        hold.cancelsTouchesInView = false
        card.contentView.addGestureRecognizer(hold)

        icon.contentMode = .scaleAspectFit
        icon.tintColor = .label

        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label

        let status = UIStackView(arrangedSubviews: [icon, label])
        status.axis = .horizontal
        status.spacing = 10
        status.alignment = .center

        memoField.placeholder = "メモを書く（あとからでも書けます）"
        memoField.font = .preferredFont(forTextStyle: .body)
        memoField.adjustsFontForContentSizeCategory = true
        memoField.borderStyle = .none
        memoField.backgroundColor = .tertiarySystemFill
        memoField.layer.cornerRadius = 12
        memoField.layer.cornerCurve = .continuous
        memoField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        memoField.leftViewMode = .always
        memoField.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        memoField.rightViewMode = .always
        memoField.returnKeyType = .done
        memoField.delegate = self

        var share = UIButton.Configuration.tinted()
        share.image = UIImage(systemName: "square.and.arrow.up")
        share.title = "ほかの人に送る"
        share.imagePadding = 6
        share.cornerStyle = .capsule
        share.buttonSize = .large
        shareButton.configuration = share
        shareButton.tintColor = .label
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)

        var done = UIButton.Configuration.filled()
        done.title = "完了"
        done.cornerStyle = .capsule
        done.buttonSize = .large
        done.baseBackgroundColor = .label
        done.baseForegroundColor = .systemBackground
        doneButton.configuration = done
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [shareButton, doneButton])
        buttons.axis = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        extras.axis = .vertical
        extras.spacing = 12
        extras.addArrangedSubview(memoField)
        extras.addArrangedSubview(buttons)
        extras.isHidden = true

        let stack = UIStackView(arrangedSubviews: [status, extras])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        let width = card.widthAnchor.constraint(equalToConstant: 420)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // キーボードが出たら、その上に乗る。
            card.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            width,
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -16),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            memoField.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
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
        if ok { savedID = entry.id }
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
        succeeded = success
        icon.image = UIImage(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        label.text = success ? "保存しました" : "保存できませんでした"
        extras.isHidden = !success
        shareButton.isHidden = shareItems.isEmpty
        if success {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        UIView.animate(withDuration: 0.18) { self.card.alpha = 1 }
        // 何もしなければ自動で閉じる。カードに触れたら待つ。
        let wait: UInt64 = success ? 3_000_000_000 : 1_600_000_000
        closing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            if Task.isCancelled { return }
            self?.close()
        }
    }

    @objc private func cardTouched() {
        closing?.cancel()
    }

    @objc private func outsideTapped(_ gesture: UITapGestureRecognizer) {
        guard !card.frame.contains(gesture.location(in: view)) else { return }
        close()
    }

    @objc private func doneTapped() {
        close()
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        closing?.cancel()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        close()
        return true
    }

    /// 保存したものを、そのままほかの人に送る（iOS の共有シートを開く）。
    @objc private func shareTapped() {
        closing?.cancel()
        storeMemo()
        memoField.resignFirstResponder()
        let sheet = UIActivityViewController(activityItems: shareItems, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = shareButton
        sheet.popoverPresentationController?.sourceRect = shareButton.bounds
        sheet.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            if completed { self?.close() }
        }
        // キーボードが下がりきってから開く。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.present(sheet, animated: true)
            // 共有シートを開けない場面では、リンクをコピーして知らせる。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.presentedViewController == nil || sheet.viewIfLoaded?.window == nil else { return }
                self.copyInstead()
            }
        }
    }

    private func copyInstead() {
        if let link = shareItems.first as? URL {
            UIPasteboard.general.url = link
        } else if let picture = shareItems.first as? UIImage {
            UIPasteboard.general.image = picture
        } else if let text = shareItems.first as? String {
            UIPasteboard.general.string = text
        }
        label.text = "コピーしました。送りたいアプリに貼り付けてください"
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
    }

    private func storeMemo() {
        let memo = (memoField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let savedID, !memo.isEmpty {
            Inbox.setMemo(memo, for: savedID)
        }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        closing?.cancel()
        storeMemo()
        memoField.resignFirstResponder()
        let success = succeeded
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
