import Foundation
import SwiftData
import SwiftUI
import CoreLocation

/// ジャンル。色はジャンルごとに1色。
enum Genre: String, CaseIterable, Identifiable, Codable {
    case place, product, event, recipe, work, article, video, image, memo, document

    var id: String { rawValue }

    var label: String {
        switch self {
        case .place: return "場所"
        case .product: return "商品"
        case .event: return "イベント"
        case .recipe: return "レシピ"
        case .work: return "作品"
        case .article: return "記事"
        case .video: return "動画"
        case .image: return "画像"
        case .memo: return "メモ"
        case .document: return "書類"
        }
    }

    var symbol: String {
        switch self {
        case .place: return "mappin"
        case .product: return "bag"
        case .event: return "calendar"
        case .recipe: return "fork.knife"
        case .work: return "book"
        case .article: return "doc.text"
        case .video: return "play.rectangle"
        case .image: return "photo"
        case .memo: return "note.text"
        case .document: return "doc"
        }
    }

    var color: Color {
        switch self {
        case .place: return .green
        case .product: return .orange
        case .event: return .pink
        case .recipe: return .yellow
        case .work: return .teal
        case .article: return .blue
        case .video: return .red
        case .image: return .purple
        case .memo, .document: return .gray
        }
    }
}

/// 取り込んだ1件。
@Model
final class Item {
    @Attribute(.unique) var id: UUID
    /// 取り込み日。
    var createdAt: Date
    var urlString: String?
    /// 共有されたときに付いていた文字。
    var rawText: String?
    var title: String
    var summary: String
    var genreRaw: String
    /// 共有元（食べログ、YouTube など）。
    var sourceName: String
    /// 検索に使う本文。
    var bodyText: String
    /// サムネイル、または取り込んだ画像そのもの。
    @Attribute(.externalStorage) var imageData: Data?
    /// imageData が利用者の画像（写真やスクリーンショット）なら true。
    var isOwnImage: Bool
    var placeName: String?
    var address: String?
    var latitude: Double?
    var longitude: Double?
    /// 予定の日付。
    var eventDate: Date?
    var calendarAdded: Bool
    /// ベクトル検索用。Float の並びをそのまま入れる。
    var embedding: Data?
    var analyzed: Bool
    var attempts: Int
    // ここから下は後から足した項目。既存のデータを引き継げるよう、初期値を持たせる。
    /// ピン留め（一覧のいちばん上に置く）。
    var pinned: Bool = false
    /// ジャンルの中の細かい分類（アニメ、寿司 など）。
    var category: String = ""
    /// 検索用の関連語。「、」区切り。
    var keywords: String = ""
    /// 要点。改行区切り。
    var points: String = ""
    /// 投稿者・チャンネル・著者。
    var author: String = ""
    /// 詳細に並べる「項目名：値」。JSON。
    var detailsData: Data? = nil
    /// 期間の最後の日。
    var eventEnd: Date? = nil
    /// 自分で書いたメモ。検索でいちばん効く。読み直しても消えない。
    var memo: String = ""
    /// どの版の解析で読んだか。古いものは読み直す。
    var analysisVersion: Int = 0

    static let currentAnalysisVersion = 3

    init(urlString: String?, rawText: String?, imageData: Data?, isOwnImage: Bool, createdAt: Date = Date()) {
        self.id = UUID()
        self.createdAt = createdAt
        self.urlString = urlString
        self.rawText = rawText
        self.title = ""
        self.summary = ""
        self.genreRaw = Genre.article.rawValue
        self.sourceName = ""
        self.bodyText = ""
        self.imageData = imageData
        self.isOwnImage = isOwnImage
        self.calendarAdded = false
        self.analyzed = false
        self.attempts = 0
    }

    var genre: Genre {
        get { Genre(rawValue: genreRaw) ?? .article }
        set { genreRaw = newValue.rawValue }
    }

    var url: URL? {
        guard let urlString else { return nil }
        return URL(string: urlString)
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host { return host }
        return analyzed ? "名称未設定" : "読み込み中"
    }

    var details: [Detail] {
        get {
            guard let detailsData else { return [] }
            return (try? JSONDecoder().decode([Detail].self, from: detailsData)) ?? []
        }
        set { detailsData = try? JSONEncoder().encode(newValue) }
    }

    var pointList: [String] {
        points.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// 予定の最後の日（期間でなければ開始日）。
    var eventLast: Date? { eventEnd ?? eventDate }

    /// 「記事・アニメ」のような表示。
    var genreText: String {
        category.isEmpty ? genre.label : genre.label + "・" + category
    }

    /// ベクトルにする文章。ページ全体ではなく、中身を表す言葉だけを使う。
    var embeddingText: String {
        [title, memo, category, keywords, summary, placeName ?? "", genre.label]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

enum DateText {
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日"
        return f
    }()
    private static let dayWithYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日(E)"
        return f
    }()
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        return f
    }()

    /// 取り込み日の表示。
    static func saved(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今日" }
        if cal.isDateInYesterday(date) { return "昨日" }
        if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            return day.string(from: date)
        }
        return dayWithYear.string(from: date)
    }

    /// 予定の日付の表示。時刻が 0:00 なら日付だけ。
    static func event(_ date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let base = cal.component(.year, from: date) == cal.component(.year, from: Date())
            ? weekday.string(from: date) : dayWithYear.string(from: date)
        if comps.hour == 0 && comps.minute == 0 { return base }
        return base + " " + time.string(from: date)
    }

    /// 期間の表示。「11月6日(金)〜12月6日(日)」。
    static func span(_ start: Date, _ end: Date?) -> String {
        guard let end, !Calendar.current.isDate(start, inSameDayAs: end) else { return event(start) }
        return weekday.string(from: start) + "〜" + weekday.string(from: end)
    }

    /// 「あと3日」「開催中」「3日前」。
    static func status(_ start: Date, _ end: Date?) -> String {
        let today = Calendar.current.startOfDay(for: Date())
        if let end, start <= Date(), end >= today, !Calendar.current.isDate(start, inSameDayAs: end) { return "開催中" }
        return remaining(start)
    }

    /// 「あと3日」「今日」「3日前」。
    static func remaining(_ date: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
        if days == 0 { return "今日" }
        if days == 1 { return "明日" }
        if days > 1 { return "あと\(days)日" }
        return "\(-days)日前"
    }
}
