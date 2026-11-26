import Foundation
import ImageIO
import UniformTypeIdentifiers

/// アプリと共有シート（拡張）の両方から使う、受け渡し用の置き場。
/// 拡張は受け取ったものをここに置くだけ。解析はアプリ本体が開いたときに行う。
enum SharedStore {
    static let appGroup = "group.com.sawswork.wellsee"

    static var inboxDirectory: URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        let dir = base.appendingPathComponent("inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 共有シートから届いた1件。
struct InboxItem: Codable {
    var id: UUID
    var date: Date
    var url: String?
    var text: String?
    /// 画像があるときのファイル名（inbox フォルダ内）。
    var imageFile: String?
    var latitude: Double?
    var longitude: Double?
}

enum Inbox {
    /// 1件を書き込む。成功したら true。
    static func write(_ item: InboxItem, imageData: Data?) -> Bool {
        guard let dir = SharedStore.inboxDirectory else { return false }
        var item = item
        do {
            if let imageData {
                let name = item.id.uuidString + ".jpg"
                try imageData.write(to: dir.appendingPathComponent(name), options: .atomic)
                item.imageFile = name
            }
            let data = try JSONEncoder().encode(item)
            try data.write(to: dir.appendingPathComponent(item.id.uuidString + ".json"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// たまっているものを古い順に読む。
    static func readAll() -> [(item: InboxItem, image: Data?)] {
        guard let dir = SharedStore.inboxDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [(item: InboxItem, image: Data?)] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let item = try? JSONDecoder().decode(InboxItem.self, from: data) else { continue }
            var image: Data?
            if let name = item.imageFile {
                image = try? Data(contentsOf: dir.appendingPathComponent(name))
            }
            out.append((item, image))
        }
        return out.sorted { $0.item.date < $1.item.date }
    }

    static func remove(_ item: InboxItem) {
        guard let dir = SharedStore.inboxDirectory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(item.id.uuidString + ".json"))
        if let name = item.imageFile {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

/// 画像を小さくして JPEG にする。メモリを食わないよう ImageIO で縮める。
enum ImageTools {
    static func jpeg(from source: CGImageSource, maxPixel: Int, quality: Double = 0.82) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func jpeg(from data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return jpeg(from: source, maxPixel: maxPixel)
    }

    /// 画像の大きさ（ピクセル）。
    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// 写真に埋め込まれた撮影場所。
    static func gps(from source: CGImageSource) -> (latitude: Double, longitude: Double)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        return (latRef == "S" ? -lat : lat, lonRef == "W" ? -lon : lon)
    }
}
