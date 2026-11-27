import Foundation
import UIKit
import Vision
import MapKit
import LinkPresentation
import FoundationModels

/// 詳細画面に並べる「項目名：値」。
struct Detail: Codable, Hashable {
    var label: String
    var value: String
}

/// 解析の結果。
struct Reading {
    var genre: Genre = .article
    /// ジャンルの中の細かい分類（アニメ、寿司 など）。
    var category = ""
    var title = ""
    var summary = ""
    var points: [String] = []
    var keywords: [String] = []
    var sourceName = ""
    /// 投稿者・チャンネル・著者。
    var author = ""
    var bodyText = ""
    var placeName: String?
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var eventStart: Date?
    var eventEnd: Date?
    var thumbnail: Data?
    var details: [Detail] = []
    /// 座標を調べるときの言葉（住所がわからないときの「エリア 店名」など）。画面には出さない。
    var locateQuery: String?
    /// ページが読めたか（通信できなかったら false。あとでやり直す）。
    var reachedPage = true

    mutating func add(_ label: String, _ value: String?) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
        guard !details.contains(where: { $0.label == label }) else { return }
        details.append(Detail(label: label, value: String(value.prefix(80))))
    }
}

/// 端末内AIに読ませる形。文字だけにしてある。
@Generable
struct AIReading {
    @Guide(description: "ジャンル。place, product, event, recipe, work, article, video, image, memo, document のどれか1つ")
    var genre: String
    @Guide(description: "ジャンルの中の細かい分類。2〜6文字の名詞を1つ（例: アニメ、寿司、コーヒー、旅行、音楽）")
    var category: String
    @Guide(description: "何についての内容かがひと目でわかる題名。30文字以内。サイト名や投稿者名は入れない")
    var title: String
    @Guide(description: "内容の要約。日本語で2〜3文。本文に書かれている事実だけ")
    var summary: String
    @Guide(description: "大事な点を3つまで。1行に1つ、改行で区切る")
    var points: String
    @Guide(description: "あとで探すための関連語を5〜8個。「、」で区切る。言い換えや上位の分類も含める")
    var keywords: String
    @Guide(description: "お店や会場など場所の名前。書かれていなければ何も書かない")
    var placeName: String
    @Guide(description: "住所。書かれていなければ何も書かない")
    var address: String
    @Guide(description: "開催日や期間の最初の日。yyyy-MM-dd 形式。書かれていなければ何も書かない")
    var dateStart: String
    @Guide(description: "期間の最後の日。yyyy-MM-dd 形式。書かれていなければ何も書かない")
    var dateEnd: String
}

/// 取り込んだものを読んで、共有元・ジャンル・分類・場所・日付などを取り出す。
/// 1. ページに埋め込まれた情報（確実）　2. サイトごとの決まり　3. 端末内AI（足りないところ）の順に使う。
enum Analyzer {
    static func read(url: URL?, text: String?, image: Data?, knownCategories: [String]) async -> Reading {
        var r = Reading()
        var ruleGenre: Genre?
        var fallback: Genre = .article
        var description = ""
        var caption = ""
        var body = ""
        var isSocial = false

        if let url {
            let host = (url.host ?? "").lowercased()
            isSocial = Sites.isSocial(host)
            r.sourceName = Sites.name(for: host) ?? host.replacingOccurrences(of: "www.", with: "")
            ruleGenre = Sites.genre(for: host)
            if let page = await Web.fetch(url) {
                let html = page.html
                let meta = Web.metaTags(html)
                let nodes = Web.jsonLD(html)
                var rawTitle = meta["og:title"] ?? Web.title(html) ?? ""
                description = meta["og:description"] ?? meta["description"] ?? meta["twitter:description"] ?? ""
                if Sites.name(for: host) == nil, let site = meta["og:site_name"], !site.isEmpty {
                    r.sourceName = site
                }
                if let g = Structured.apply(nodes, to: &r) { ruleGenre = g }
                Special.apply(host: host, html: html, meta: meta, reading: &r,
                              rawTitle: &rawTitle, description: &description, caption: &caption)
                if ruleGenre == nil {
                    if isSocial, meta["og:video"] != nil || (meta["og:type"] ?? "").hasPrefix("video") {
                        ruleGenre = .video
                    } else {
                        ruleGenre = Sites.genre(forOGType: meta["og:type"])
                    }
                }
                if r.latitude == nil,
                   let lat = Double(meta["place:location:latitude"] ?? ""),
                   let lon = Double(meta["place:location:longitude"] ?? "") {
                    r.latitude = lat
                    r.longitude = lon
                }
                if r.latitude == nil,
                   let c = Web.coordinate(in: page.finalURL.absoluteString) ?? Web.coordinate(in: url.absoluteString) {
                    r.latitude = c.0
                    r.longitude = c.1
                }
                if r.author.isEmpty, let a = meta["author"] ?? meta["article:author"], !a.hasPrefix("http") { r.author = a }
                r.add("公開日", Dates.display(meta["article:published_time"] ?? meta["datepublished"] ?? meta["uploaddate"]))
                if let amount = meta["product:price:amount"] {
                    r.add("価格", Format.price(amount, currency: meta["product:price:currency"]))
                }
                r.title = Web.cleanTitle(rawTitle, site: r.sourceName, host: host)
                body = Web.mainText(html)
                r.thumbnail = await Web.bestImage(html: html, meta: meta, nodes: nodes, base: page.finalURL, original: url)
            } else {
                r.reachedPage = false
            }
            if r.title.isEmpty, !isSocial { r.title = firstLine(text) ?? "" }
        } else if image != nil {
            r.sourceName = "写真・画像"
            fallback = .image
        } else {
            r.sourceName = "テキスト"
            fallback = .memo
        }

        // 画像に書かれた文字。SNS や動画は、日付や店名がサムネイルに書かれていることが多い。
        var seen = ""
        if let image, let cg = UIImage(data: image)?.cgImage {
            seen = await Eyes.readText(cg)
        } else if isSocial || ruleGenre == .video || ruleGenre == nil,
                  let thumb = r.thumbnail, let cg = UIImage(data: thumb)?.cgImage {
            seen = await Eyes.readText(cg)
        }

        // 信頼できる文章（題名・説明・投稿文・共有時の文字・画像の文字）。日付や要点はここから探す。
        let focus = [r.title, caption.isEmpty ? description : caption, text ?? "", seen]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        r.bodyText = String((focus + "\n" + body).prefix(4000))
        if url == nil { r.title = firstLine(focus) ?? (image != nil ? "画像" : "メモ") }

        // 端末内AI。使えない端末では何もしない。
        let ai = await Brain.read(source: r.sourceName, title: r.title, focus: focus, body: body,
                                  knownCategories: knownCategories)

        // 要約・要点・関連語
        let fallbackSummary = caption.isEmpty ? description : caption
        r.summary = Clean.text(ai?.summary).isEmpty ? String(fallbackSummary.prefix(160)) : Clean.text(ai?.summary)
        r.points = Clean.lines(ai?.points, limit: 3)
        r.keywords = Clean.words(ai?.keywords, limit: 10)

        // 題名。SNS の投稿、長い商品名、投稿者名そのままの題名は、内容を表す題名に置き換える。
        // 記事や動画の題名は、長くても元のままにする（その題名で覚えているため）。
        let aiTitle = Clean.text(ai?.title)
        let longProductName = ruleGenre == .product && r.title.count > 40
        if url == nil || isSocial || r.title.isEmpty || longProductName || r.title == r.author {
            if !aiTitle.isEmpty {
                r.title = aiTitle
            } else if isSocial || r.title.isEmpty {
                r.title = firstLine(caption) ?? firstLine(description) ?? (r.author.isEmpty ? r.sourceName : r.author + "の投稿")
            }
        }

        // 予定。確かな日付で、まだ終わっていないものだけ登録する。
        if r.eventStart == nil {
            if let start = Dates.parse(Clean.text(ai?.dateStart)) {
                r.eventStart = start
                r.eventEnd = Dates.parse(Clean.text(ai?.dateEnd))
            } else if let span = Dates.span(in: focus) {
                r.eventStart = span.start
                r.eventEnd = span.end
            }
        }
        if let start = r.eventStart {
            if let end = r.eventEnd, end < start { r.eventEnd = nil }
            let last = r.eventEnd ?? start
            if last < Calendar.current.startOfDay(for: Date()) {
                r.eventStart = nil
                r.eventEnd = nil
            }
        }

        // ジャンル。イベントと言い切るのは、ページがそう示しているか、これからの日付があるときだけ。
        var genre = ruleGenre ?? Genre(rawValue: Clean.text(ai?.genre)) ?? fallback
        if ruleGenre == nil, genre == .event, r.eventStart == nil { genre = fallback }
        r.genre = genre

        // 分類
        if r.category.isEmpty {
            let c = Clean.text(ai?.category)
            if !c.isEmpty, c.count <= 8, c != genre.label { r.category = c }
        }

        // 場所
        if genre == .place || genre == .event || r.eventStart != nil {
            if r.placeName == nil { r.placeName = Clean.nonEmpty(ai?.placeName) }
            if r.address == nil { r.address = Clean.nonEmpty(ai?.address) }
        }
        if genre == .place, r.placeName == nil, !r.title.isEmpty { r.placeName = r.title }
        if r.latitude == nil, genre == .place || r.eventStart != nil || r.address != nil {
            let query = r.address ?? r.locateQuery ?? r.placeName ?? ""
            if !query.isEmpty, let c = await Eyes.locate(query) {
                r.latitude = c.latitude
                r.longitude = c.longitude
            }
        }
        if !r.author.isEmpty { r.add(isSocial || genre == .video ? "投稿者" : "著者", r.author) }
        return r
    }

    static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(36)) }
        }
        return nil
    }
}

// MARK: - 文字の後始末

enum Clean {
    private static let placeholders: Set<String> = [
        "空文字", "なし", "無し", "不明", "未定", "該当なし", "特になし", "n/a", "na", "null", "none", "-", "ー", "―", "?", "？",
    ]

    /// AI が「なし」の意味で返した言葉を空にする。
    static func text(_ s: String?) -> String {
        guard let s else { return "" }
        let t = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"「」")))
        return placeholders.contains(t.lowercased()) ? "" : t
    }

    static func nonEmpty(_ s: String?) -> String? {
        let t = text(s)
        return t.isEmpty ? nil : t
    }

    static func lines(_ s: String?, limit: Int) -> [String] {
        guard let s else { return [] }
        return s.split(whereSeparator: \.isNewline)
            .map { text(String($0).trimmingCharacters(in: CharacterSet(charactersIn: "・-•*0123456789. 　"))) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { String($0.prefix(80)) }
    }

    static func words(_ s: String?, limit: Int) -> [String] {
        guard let s else { return [] }
        var out: [String] = []
        for part in s.components(separatedBy: CharacterSet(charactersIn: "、,，・\n")) {
            let w = text(part)
            if !w.isEmpty, w.count <= 16, !out.contains(w) { out.append(w) }
        }
        return Array(out.prefix(limit))
    }
}

enum Format {
    static func price(_ amount: String, currency: String?) -> String? {
        let digits = amount.replacingOccurrences(of: ",", with: "")
        guard let value = Double(digits), value > 0 else { return nil }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = value == value.rounded() ? 0 : 2
        let number = f.string(from: NSNumber(value: value)) ?? digits
        let code = (currency ?? "JPY").uppercased()
        if code == "JPY" { return "¥" + number }
        if code == "USD" { return "$" + number }
        return number + " " + code
    }

    /// 秒数 → 「1時間5分」「3分20秒」。
    static func duration(seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return "\(h)時間\(m)分" }
        if m > 0 { return s > 0 ? "\(m)分\(s)秒" : "\(m)分" }
        return "\(s)秒"
    }

    /// ISO 8601 の長さ（PT1H30M）。
    static func duration(iso: String?) -> String? {
        guard let iso, let m = Web.matches("PT(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?", in: iso).first else { return nil }
        let total = (Int(m[1]) ?? 0) * 3600 + (Int(m[2]) ?? 0) * 60 + (Int(m[3]) ?? 0)
        return total > 0 ? duration(seconds: total) : nil
    }
}

// MARK: - サイトごとの決まり

enum Sites {
    private static let names: [(String, String)] = [
        ("tabelog.com", "食べログ"), ("youtube.com", "YouTube"), ("youtu.be", "YouTube"),
        ("instagram.com", "Instagram"), ("tiktok.com", "TikTok"), ("twitter.com", "X"), ("x.com", "X"),
        ("threads.net", "Threads"), ("threads.com", "Threads"), ("facebook.com", "Facebook"),
        ("amazon.co.jp", "Amazon"), ("amazon.com", "Amazon"), ("amzn.asia", "Amazon"), ("amzn.to", "Amazon"),
        ("rakuten.co.jp", "楽天市場"), ("mercari.com", "メルカリ"), ("zozo.jp", "ZOZOTOWN"),
        ("shopping.yahoo.co.jp", "Yahoo!ショッピング"),
        ("maps.app.goo.gl", "Googleマップ"), ("google.com/maps", "Googleマップ"), ("maps.google", "Googleマップ"),
        ("maps.apple.com", "マップ"), ("retty.me", "Retty"), ("hotpepper.jp", "ホットペッパー"),
        ("gnavi.co.jp", "ぐるなび"), ("jalan.net", "じゃらん"), ("ikyu.com", "一休"),
        ("cookpad.com", "クックパッド"), ("kurashiru.com", "クラシル"), ("delishkitchen.tv", "デリッシュキッチン"),
        ("filmarks.com", "Filmarks"), ("eiga.com", "映画.com"), ("bookmeter.com", "読書メーター"),
        ("peatix.com", "Peatix"), ("connpass.com", "connpass"), ("eplus.jp", "イープラス"), ("t.pia.jp", "チケットぴあ"),
        ("note.com", "note"), ("nicovideo.jp", "ニコニコ動画"), ("vimeo.com", "Vimeo"),
        ("pinterest.", "Pinterest"),
    ]

    static func name(for host: String) -> String? {
        names.first { host.contains($0.0) }?.1
    }

    static func isSocial(_ host: String) -> Bool {
        ["instagram.com", "tiktok.com", "twitter.com", "x.com", "threads.net", "threads.com", "facebook.com"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func genre(for host: String) -> Genre? {
        let video = ["youtube.com", "youtu.be", "tiktok.com", "nicovideo.jp", "vimeo.com"]
        let place = ["tabelog.com", "maps.app.goo.gl", "maps.google", "maps.apple.com", "retty.me",
                     "hotpepper.jp", "gnavi.co.jp", "jalan.net", "ikyu.com"]
        let product = ["amazon.", "amzn.", "item.rakuten.co.jp", "mercari.com", "zozo.jp", "shopping.yahoo.co.jp"]
        let recipe = ["cookpad.com", "kurashiru.com", "delishkitchen.tv"]
        let work = ["filmarks.com", "eiga.com", "bookmeter.com", "booklog.jp"]
        let event = ["peatix.com", "connpass.com", "eplus.jp", "t.pia.jp", "livepocket.jp"]
        func has(_ list: [String]) -> Bool { list.contains { host.contains($0) } }
        if has(video) { return .video }
        if has(place) { return .place }
        if has(product) { return .product }
        if has(recipe) { return .recipe }
        if has(work) { return .work }
        if has(event) { return .event }
        return nil
    }

    static func genre(forOGType type: String?) -> Genre? {
        guard let type = type?.lowercased() else { return nil }
        if type.hasPrefix("video.movie") || type.hasPrefix("video.tv_show") || type.hasPrefix("book") || type.hasPrefix("music.album") {
            return .work
        }
        if type.hasPrefix("video") { return .video }
        if type.hasPrefix("product") { return .product }
        if type.hasPrefix("place") || type.hasPrefix("restaurant") { return .place }
        return nil
    }
}

/// よく使うサイトは、そのサイトの書き方に合わせて読む。
enum Special {
    static func apply(host: String, html: String, meta: [String: String], reading r: inout Reading,
                      rawTitle: inout String, description: inout String, caption: inout String) {
        if Sites.isSocial(host) {
            social(meta: meta, reading: &r, rawTitle: &rawTitle, description: description, caption: &caption)
        } else if host.contains("youtube.com") || host.contains("youtu.be") {
            youtube(html: html, reading: &r, description: &description)
        } else if host.contains("amazon.") || host.contains("amzn.") {
            amazon(html: html, reading: &r, rawTitle: &rawTitle)
        } else if host.contains("tabelog.com") {
            tabelog(reading: &r, rawTitle: &rawTitle)
        }
    }

    /// SNS：題名に入っているのは投稿者名なので、投稿者と投稿文に分ける。
    private static func social(meta: [String: String], reading r: inout Reading,
                               rawTitle: inout String, description: String, caption: inout String) {
        var author = rawTitle
        // 英語の「名前 on Instagram: "…"」と、日本語の「名前 - Instagram: "…"」「名前さんはInstagramを…」の両方に合わせる。
        for marker in [" on Instagram", " on TikTok", " on X", " on Threads", "(@", "（@",
                       " - Instagram", " - TikTok", " - Threads", " | Instagram", " | TikTok", " | Threads",
                       " • Instagram", " / X", "さんはInstagram", "さん: ", "さん：",
                       ": \"", ": “", ":\"", ":“", "\n"] {
            if let range = author.range(of: marker) { author = String(author[..<range.lowerBound]) }
        }
        author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        // 切り分けられずに投稿文まで残ったときは、投稿者として出さない。
        r.author = author.count <= 40 ? author : ""
        // 「… likes, … comments - 名前 on 日付: "投稿文"」から投稿文を取り出す。
        if let m = Web.matches(":\\s*[\"“”](.+)[\"“”]\\s*\\.?\\s*$", in: description).first {
            caption = m[1]
        } else if let m = Web.matches(":\\s*[\"“”](.+)[\"“”]", in: rawTitle).first {
            caption = m[1]
        } else {
            caption = description
        }
        rawTitle = ""
    }

    private static func youtube(html: String, reading r: inout Reading, description: inout String) {
        if let m = Web.matches("\"ownerChannelName\":\"((?:[^\"\\\\]|\\\\.)*)\"", in: html).first {
            r.author = unescape(m[1])
        }
        if let m = Web.matches("\"lengthSeconds\":\"(\\d+)\"", in: html).first, let seconds = Int(m[1]), seconds > 0 {
            r.add("長さ", Format.duration(seconds: seconds))
        }
        if let m = Web.matches("\"shortDescription\":\"((?:[^\"\\\\]|\\\\.)*)\"", in: html).first {
            let full = unescape(m[1])
            if full.count > description.count { description = String(full.prefix(700)) }
        }
        if let m = Web.matches("\"(?:publishDate|uploadDate)\":\"([^\"]+)\"", in: html).first {
            r.add("公開日", Dates.display(m[1]))
        }
    }

    private static func amazon(html: String, reading r: inout Reading, rawTitle: inout String) {
        var t = rawTitle
        t = t.replacingOccurrences(of: "^Amazon(\\.co\\.jp|\\.com)?\\s*[:：|｜]\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        // 末尾の「 : 食品・飲料・お酒」は売り場の名前。
        if let range = t.range(of: " : ", options: .backwards) {
            let tail = String(t[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if tail.count <= 20 {
                r.add("売り場", tail)
                t = String(t[..<range.lowerBound])
            }
        }
        rawTitle = t
        if let m = Web.matches("class=\"a-offscreen\">\\s*([￥¥$][0-9,\\.]+)", in: html).first {
            r.add("価格", m[1].replacingOccurrences(of: "￥", with: "¥"))
        }
        if let m = Web.matches("id=\"bylineInfo\"[^>]*>([^<]+)<", in: html).first {
            var brand = Web.decodeEntities(m[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            for noise in ["ブランド: ", "のストアを表示", "Visit the ", " Store", "Brand: "] {
                brand = brand.replacingOccurrences(of: noise, with: "")
            }
            r.add("ブランド", brand)
        }
        if let m = Web.matches("5つ星のうち\\s*([0-9.]+)", in: html).first {
            r.add("評価", "★" + m[1])
        }
    }

    /// 食べログ：題名は「店名 - エリア/料理」。予約ページは「店名のご予約 - …」。
    private static func tabelog(reading r: inout Reading, rawTitle: inout String) {
        var t = rawTitle.replacingOccurrences(of: "\\s*[\\[［【]食べログ[\\]］】]\\s*$", with: "", options: .regularExpression)
        var tail = ""
        if let range = t.range(of: " - ") {
            tail = String(t[range.upperBound...])
            t = String(t[..<range.lowerBound])
        }
        t = t.replacingOccurrences(of: "のご予約$|の予約$|のメニュー$|の口コミ.*$|の写真.*$|の地図.*$", with: "", options: .regularExpression)
        let name = t.trimmingCharacters(in: .whitespaces)
        rawTitle = name
        if r.placeName == nil, !name.isEmpty { r.placeName = name }
        let parts = tail.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        if let area = parts.first, !area.isEmpty {
            r.add("エリア", area)
            if r.address == nil, r.latitude == nil { r.locateQuery = area + " " + name }
        }
        if parts.count > 1 {
            let cuisine = parts[1].replacingOccurrences(of: "、", with: "・")
            r.add("料理", cuisine)
            if r.category.isEmpty { r.category = String(cuisine.split(separator: "・").first ?? "") }
        }
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

// MARK: - ページに埋め込まれた情報（JSON-LD）

enum Structured {
    private static let placeTypes: Set<String> = [
        "Place", "LocalBusiness", "Restaurant", "FoodEstablishment", "CafeOrCoffeeShop", "BarOrPub", "Bakery",
        "Hotel", "LodgingBusiness", "TouristAttraction", "Store", "Museum", "Park", "Campground",
    ]
    private static let workTypes: Set<String> = ["Movie", "Book", "TVSeries", "MusicAlbum", "VideoGame"]
    private static let articleTypes: Set<String> = ["Article", "NewsArticle", "BlogPosting"]

    /// 情報を r に書き込み、ジャンルが決まればそれを返す。
    static func apply(_ nodes: [[String: Any]], to r: inout Reading) -> Genre? {
        var found: Genre?
        func rank(_ g: Genre) -> Int {
            switch g {
            case .event: return 7
            case .place: return 6
            case .recipe: return 5
            case .product: return 4
            case .work: return 3
            case .video: return 2
            default: return 1
            }
        }
        func take(_ g: Genre) {
            if found == nil || rank(g) > rank(found!) { found = g }
        }
        // 1ページに1つだけのイベントを「イベント」とみなす（一覧ページは記事として扱う）。
        let eventCount = nodes.filter { n in typeNames(n).contains { $0.hasSuffix("Event") } }.count
        for node in nodes {
            let types = typeNames(node)
            if types.contains(where: { $0.hasSuffix("Event") }) {
                guard eventCount == 1 else { continue }
                take(.event)
                if let s = node["startDate"] as? String { r.eventStart = Dates.parse(s) }
                if let s = node["endDate"] as? String { r.eventEnd = Dates.parse(s) }
                if let location = node["location"] as? [String: Any] {
                    if r.placeName == nil { r.placeName = location["name"] as? String }
                    readPlace(location, into: &r)
                }
                r.add("料金", price(node["offers"]))
            } else if types.contains(where: { placeTypes.contains($0) }) {
                take(.place)
                if r.placeName == nil { r.placeName = node["name"] as? String }
                readPlace(node, into: &r)
                let cuisine = strings(node["servesCuisine"]).joined(separator: "・")
                r.add("料理", cuisine)
                if r.category.isEmpty, let first = strings(node["servesCuisine"]).first { r.category = String(first.prefix(8)) }
                r.add("予算", node["priceRange"] as? String)
                r.add("電話", node["telephone"] as? String)
                r.add("評価", rating(node["aggregateRating"]))
                r.add("営業時間", strings(node["openingHours"]).prefix(2).joined(separator: " / "))
            } else if types.contains("Recipe") {
                take(.recipe)
                r.add("調理時間", Format.duration(iso: (node["totalTime"] ?? node["cookTime"]) as? String))
                r.add("分量", strings(node["recipeYield"]).first)
                let ingredients = strings(node["recipeIngredient"])
                if !ingredients.isEmpty {
                    r.add("材料", "\(ingredients.count)品（" + ingredients.prefix(4).joined(separator: "、") + (ingredients.count > 4 ? " ほか）" : "）"))
                }
                r.author = name(node["author"]) ?? r.author
            } else if types.contains("Product") {
                take(.product)
                r.add("価格", price(node["offers"]))
                r.add("ブランド", name(node["brand"]))
                r.add("評価", rating(node["aggregateRating"]))
            } else if types.contains(where: { workTypes.contains($0) }) {
                take(.work)
                r.add("作者", name(node["author"]) ?? name(node["director"]) ?? name(node["byArtist"]))
                r.add("公開日", Dates.display((node["datePublished"] ?? node["dateCreated"]) as? String))
                r.add("評価", rating(node["aggregateRating"]))
            } else if types.contains("VideoObject") {
                take(.video)
                r.add("長さ", Format.duration(iso: node["duration"] as? String))
                r.add("公開日", Dates.display(node["uploadDate"] as? String))
                if r.author.isEmpty { r.author = name(node["author"]) ?? "" }
            } else if types.contains(where: { articleTypes.contains($0) }) {
                take(.article)
                if r.author.isEmpty { r.author = name(node["author"]) ?? "" }
                r.add("公開日", Dates.display(node["datePublished"] as? String))
            }
        }
        return found
    }

    static func imageURLs(_ nodes: [[String: Any]]) -> [String] {
        var out: [String] = []
        for node in nodes {
            for key in ["image", "thumbnailUrl"] {
                if let s = node[key] as? String { out.append(s) }
                if let a = node[key] as? [Any] {
                    for e in a {
                        if let s = e as? String { out.append(s) }
                        if let d = e as? [String: Any], let s = d["url"] as? String { out.append(s) }
                    }
                }
                if let d = node[key] as? [String: Any], let s = d["url"] as? String { out.append(s) }
            }
        }
        return out
    }

    private static func typeNames(_ node: [String: Any]) -> [String] {
        if let s = node["@type"] as? String { return [s] }
        if let a = node["@type"] as? [String] { return a }
        return []
    }

    private static func readPlace(_ node: [String: Any], into r: inout Reading) {
        if r.address == nil { r.address = addressText(node["address"]) }
        if r.latitude == nil, let geo = node["geo"] as? [String: Any],
           let lat = number(geo["latitude"]), let lon = number(geo["longitude"]) {
            r.latitude = lat
            r.longitude = lon
        }
    }

    private static func addressText(_ any: Any?) -> String? {
        if let s = any as? String { return s.isEmpty ? nil : s }
        if let d = any as? [String: Any] {
            let joined = ["addressRegion", "addressLocality", "streetAddress"]
                .compactMap { d[$0] as? String }
                .joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func strings(_ any: Any?) -> [String] {
        if let s = any as? String { return s.isEmpty ? [] : [s] }
        if let a = any as? [Any] { return a.compactMap { $0 as? String } }
        if let n = any as? NSNumber { return [n.stringValue] }
        return []
    }

    private static func name(_ any: Any?) -> String? {
        if let s = any as? String { return s.hasPrefix("http") ? nil : s }
        if let d = any as? [String: Any] { return d["name"] as? String }
        if let a = any as? [Any] { return a.compactMap { name($0) }.first }
        return nil
    }

    private static func price(_ any: Any?) -> String? {
        var offer = any as? [String: Any]
        if offer == nil, let list = any as? [Any] { offer = list.first as? [String: Any] }
        guard let offer else { return nil }
        let amount = offer["price"] ?? offer["lowPrice"]
        var text: String?
        if let n = amount as? NSNumber { text = n.stringValue }
        if let s = amount as? String { text = s }
        guard let text else { return nil }
        return Format.price(text, currency: offer["priceCurrency"] as? String)
    }

    private static func rating(_ any: Any?) -> String? {
        guard let d = any as? [String: Any], let value = number(d["ratingValue"]) else { return nil }
        var text = "★" + String(format: "%.1f", value)
        if let count = number(d["reviewCount"]) ?? number(d["ratingCount"]) { text += "（\(Int(count))件）" }
        return text
    }
}

// MARK: - ページの取得と読み取り

enum Web {
    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func fetch(_ url: URL) async -> (html: String, finalURL: URL)? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("ja,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let head = Data(data.prefix(2_500_000))
        let html = String(data: head, encoding: .utf8)
            ?? String(data: head, encoding: .shiftJIS)
            ?? String(data: head, encoding: .japaneseEUC)
            ?? String(decoding: head, as: UTF8.self)
        return (html, response.url ?? url)
    }

    static func downloadImage(_ url: URL, minPixel: Int) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request), data.count < 12_000_000,
              let size = ImageTools.pixelSize(data), min(size.width, size.height) >= minPixel else {
            return nil
        }
        return ImageTools.jpeg(from: data, maxPixel: 900)
    }

    /// ひと目でわかる画像を、確かな順に探す。最後はサイトのアイコン。
    static func bestImage(html: String, meta: [String: String], nodes: [[String: Any]], base: URL, original: URL) async -> Data? {
        var candidates: [String] = []
        for key in ["og:image", "og:image:secure_url", "og:image:url", "twitter:image", "twitter:image:src"] {
            if let v = meta[key] { candidates.append(v) }
        }
        candidates += Structured.imageURLs(nodes)
        // 通販サイトの商品写真
        for pattern in ["\"hiRes\":\"(https:[^\"]+)\"", "data-old-hires=\"(https:[^\"]+)\"",
                        "id=\"landingImage\"[^>]*src=\"(https:[^\"]+)\"", "\"large\":\"(https:[^\"]+)\"",
                        "<link[^>]+rel=[\"']image_src[\"'][^>]*href=[\"']([^\"']+)[\"']"] {
            if let m = matches(pattern, in: html).first { candidates.append(m[1].replacingOccurrences(of: "\\/", with: "/")) }
        }
        // 本文の最初のほうにある写真
        for m in matches("<img[^>]+src=[\"']([^\"']+\\.(?:jpe?g|png|webp)[^\"']*)[\"']", in: html).prefix(6) {
            let src = m[1].lowercased()
            if !src.contains("logo") && !src.contains("icon") && !src.contains("sprite") && !src.contains("blank") {
                candidates.append(m[1])
            }
        }
        var tried: Set<String> = []
        for candidate in candidates.prefix(8) {
            let cleaned = decodeEntities(candidate)
            guard tried.insert(cleaned).inserted, let url = URL(string: cleaned, relativeTo: base)?.absoluteURL else { continue }
            if let data = await downloadImage(url, minPixel: 120) { return data }
        }
        // ここまでで見つからなければ、iPhone のリンクプレビューのしくみに頼る。
        let preview = await LinkPreview.fetch(original)
        if let image = preview.image { return image }
        // 最後の手段：サイトのアイコン。
        var icons: [String] = []
        if let m = matches("<link[^>]+rel=[\"']apple-touch-icon[^\"']*[\"'][^>]*href=[\"']([^\"']+)[\"']", in: html).first { icons.append(m[1]) }
        if let m = matches("<link[^>]+href=[\"']([^\"']+)[\"'][^>]*rel=[\"']apple-touch-icon", in: html).first { icons.append(m[1]) }
        icons.append("/apple-touch-icon.png")
        for icon in icons {
            guard let url = URL(string: decodeEntities(icon), relativeTo: base)?.absoluteURL else { continue }
            if let data = await downloadImage(url, minPixel: 48) { return data }
        }
        return preview.icon
    }

    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let ns = text as NSString
        return re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let range = m.range(at: i)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }

    static func metaTags(_ html: String) -> [String: String] {
        var out: [String: String] = [:]
        for tag in matches("<meta\\b[^>]*>", in: html) {
            var attrs: [String: String] = [:]
            for a in matches("([a-zA-Z:_-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", in: tag[0]) {
                attrs[a[1].lowercased()] = a[2].isEmpty ? a[3] : a[2]
            }
            guard let content = attrs["content"], !content.isEmpty,
                  let key = attrs["property"] ?? attrs["name"] ?? attrs["itemprop"] else { continue }
            let k = key.lowercased()
            if out[k] == nil { out[k] = decodeEntities(content) }
        }
        return out
    }

    static func title(_ html: String) -> String? {
        guard let m = matches("<title[^>]*>(.*?)</title>", in: html).first else { return nil }
        let t = decodeEntities(m[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func jsonLD(_ html: String) -> [[String: Any]] {
        var nodes: [[String: Any]] = []
        var stack: [Any] = []
        for m in matches("<script[^>]*type\\s*=\\s*[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>", in: html) {
            if let data = m[1].data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                stack.append(obj)
            }
        }
        while let any = stack.popLast() {
            if let array = any as? [Any] {
                stack.append(contentsOf: array)
            } else if let dict = any as? [String: Any] {
                nodes.append(dict)
                if let graph = dict["@graph"] { stack.append(graph) }
            }
        }
        return nodes
    }

    /// 本文の文字だけを取り出す。記事の本体（article / main）があればそこだけを見る。
    static func mainText(_ html: String) -> String {
        var source = html
        for tag in ["article", "main"] {
            if let m = matches("<\(tag)\\b[^>]*>(.*?)</\(tag)>", in: html).first, m[1].count > 400 {
                source = m[1]
                break
            }
        }
        guard let strip = try? NSRegularExpression(
            pattern: "<(script|style|noscript|svg|header|footer|nav|aside|form)\\b.*?</\\1>|<[^>]+>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return "" }
        let ns = source as NSString
        var text = strip.stringByReplacingMatches(in: source, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        text = decodeEntities(text)
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return String(words.joined(separator: " ").prefix(3000))
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let table = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (k, v) in table { out = out.replacingOccurrences(of: k, with: v) }
        for m in matches("&#(x?)([0-9a-fA-F]+);", in: out) {
            let radix = m[1].isEmpty ? 10 : 16
            if let code = UInt32(m[2], radix: radix), let scalar = Unicode.Scalar(code) {
                out = out.replacingOccurrences(of: m[0], with: String(Character(scalar)))
            }
        }
        return out
    }

    /// 題名からサイト名などの飾りを落とし、中身の名前だけにする。
    static func cleanTitle(_ raw: String, site: String, host: String) -> String {
        var t = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        let hostCore = host.replacingOccurrences(of: "www.", with: "").split(separator: ".").first.map(String.init) ?? ""
        func isSiteName(_ part: String) -> Bool {
            let p = part.lowercased()
            if !site.isEmpty, p.contains(site.lowercased()) || site.lowercased().contains(p) { return true }
            return hostCore.count >= 3 && p.contains(hostCore)
        }
        // 「A | B | サイト名」は、サイト名でない最初の部分を採る。
        let parts = t.components(separatedBy: CharacterSet(charactersIn: "|｜"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parts.count > 1 {
            t = parts.first { !isSiteName($0) } ?? parts[0]
        }
        // 末尾の「 - サイト名」「【サイト名】」を落とす。
        for separator in [" - ", " – ", " — ", " : ", "："] {
            if let range = t.range(of: separator, options: .backwards) {
                let tail = String(t[range.upperBound...])
                if isSiteName(tail), t.distance(from: t.startIndex, to: range.lowerBound) >= 2 {
                    t = String(t[..<range.lowerBound])
                }
            }
        }
        if !site.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: site)
            t = t.replacingOccurrences(of: "\\s*[\\[［【(（]\\s*" + escaped + "\\s*[\\]］】)）]\\s*$", with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// 地図の URL に入っている座標。
    static func coordinate(in urlString: String) -> (Double, Double)? {
        let patterns = ["!3d(-?\\d+\\.\\d+)!4d(-?\\d+\\.\\d+)", "@(-?\\d+\\.\\d+),(-?\\d+\\.\\d+)",
                        "[?&](?:q|ll|query)=(-?\\d+\\.\\d+)(?:,|%2C)(-?\\d+\\.\\d+)"]
        for p in patterns {
            if let m = matches(p, in: urlString).first, let lat = Double(m[1]), let lon = Double(m[2]),
               abs(lat) <= 90, abs(lon) <= 180 {
                return (lat, lon)
            }
        }
        return nil
    }
}

/// iPhone 標準のリンクプレビュー。自前で画像が見つからないときの頼み。
@MainActor
enum LinkPreview {
    static func fetch(_ url: URL) async -> (image: Data?, icon: Data?) {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return (nil, nil) }
        let image = await load(metadata.imageProvider, minPixel: 120)
        let icon = image == nil ? await load(metadata.iconProvider, minPixel: 48) : nil
        return (image, icon)
    }

    private static func load(_ provider: NSItemProvider?, minPixel: Int) async -> Data? {
        guard let provider, provider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage,
                      min(image.size.width * image.scale, image.size.height * image.scale) >= CGFloat(minPixel),
                      let data = image.jpegData(compressionQuality: 0.85) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: ImageTools.jpeg(from: data, maxPixel: 900))
            }
        }
    }
}

// MARK: - 日付

enum Dates {
    static func parse(_ text: String) -> Date? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// 詳細に出す日付（2026年11月21日）。
    static func display(_ text: String?) -> String? {
        guard let text, let date = parse(String(text.prefix(25))) ?? parse(String(text.prefix(10))) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日"
        return f.string(from: date)
    }

    private static let cues = ["開催", "期間", "限定", "まで", "から", "開幕", "公開", "発売", "予約", "締切", "〆切",
                               "イベント", "ライブ", "上映", "開園", "オープン", "スタート", "実施", "販売"]

    /// 文章に書かれた日付や期間。まだ終わっていないものだけ返す。
    /// 1日だけの日付は、近くに「開催」「まで」などの言葉があるときだけ採る（投稿日などを拾わないため）。
    static func span(in text: String) -> (start: Date, end: Date?)? {
        let head = String(text.prefix(900))
        let ns = head as NSString
        let today = Calendar.current.startOfDay(for: Date())
        let year = "(?:(\\d{4})\\s*[年/.]\\s*)?"
        let day = "(\\d{1,2})\\s*[月/]\\s*(\\d{1,2})\\s*日?"
        let rangePattern = year + day + "[^0-9\\n]{0,8}?[〜~～－–—-][^0-9\\n]{0,4}?" + year + "(?:(\\d{1,2})\\s*[月/]\\s*)?(\\d{1,2})\\s*日?"

        func group(_ m: NSTextCheckingResult, _ i: Int) -> Int? {
            let range = m.range(at: i)
            return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
        }
        func make(_ y: Int?, _ m: Int, _ d: Int) -> Date? {
            guard (1...12).contains(m), (1...31).contains(d) else { return nil }
            let cal = Calendar.current
            var comps = DateComponents(year: y ?? cal.component(.year, from: Date()), month: m, day: d)
            guard var date = cal.date(from: comps) else { return nil }
            // 年が書かれていないとき、4か月以上前になるなら来年とみなす。
            if y == nil, let limit = cal.date(byAdding: .day, value: -120, to: today), date < limit {
                comps.year = (comps.year ?? 0) + 1
                date = cal.date(from: comps) ?? date
            }
            return date
        }

        if let re = try? NSRegularExpression(pattern: rangePattern) {
            for m in re.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
                guard let m1 = group(m, 2), let d1 = group(m, 3), let d2 = group(m, 6),
                      let start = make(group(m, 1), m1, d1) else { continue }
                let m2 = group(m, 5) ?? m1
                let cal = Calendar.current
                var endYear = group(m, 4) ?? cal.component(.year, from: start)
                if group(m, 4) == nil, m2 < m1 { endYear += 1 }
                guard let end = make(endYear, m2, d2), end >= start, end >= today else { continue }
                // 期間が長すぎるものは、日付の読み違いとみなす。
                if end.timeIntervalSince(start) > 400 * 86400 { continue }
                return (start, end)
            }
        }
        if let re = try? NSRegularExpression(pattern: year + day) {
            for m in re.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
                guard let month = group(m, 2), let dayNumber = group(m, 3),
                      let date = make(group(m, 1), month, dayNumber), date >= today else { continue }
                let from = max(0, m.range.location - 14)
                let to = min(ns.length, m.range.location + m.range.length + 14)
                let around = ns.substring(with: NSRange(location: from, length: to - from))
                if cues.contains(where: { around.contains($0) }) { return (date, nil) }
            }
        }
        return nil
    }
}

// MARK: - 画像の文字と、場所の座標

enum Eyes {
    static func readText(_ image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ja-JP", "en-US"]
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try? handler.perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }

    /// 名前や住所から座標を調べる。日本で使っているときは、日本の中だけを探す
    /// （「横浜市」が海外の同名の場所に当たらないようにする）。
    static func locate(_ query: String) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let inJapan = Locale.current.region?.identifier == "JP"
        if inJapan {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 36.2, longitude: 138.2),
                span: MKCoordinateSpan(latitudeDelta: 24, longitudeDelta: 30))
        }
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        for item in response.mapItems.prefix(5) {
            let c = item.placemark.coordinate
            if !inJapan { return c }
            if (20...46).contains(c.latitude), (122...154).contains(c.longitude) { return c }
        }
        return nil
    }
}

// MARK: - 端末内AI

enum Brain {
    static func read(source: String, title: String, focus: String, body: String,
                     knownCategories: [String]) async -> AIReading? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let main = String(focus.prefix(700))
        let rest = String(body.prefix(700))
        guard !(main.isEmpty && rest.isEmpty) else { return nil }
        var prompt = "共有元: \(source)\n題名: \(title)\n内容:\n\(main)"
        if !rest.isEmpty { prompt += "\n\nページの本文（参考）:\n\(rest)" }
        if !knownCategories.isEmpty {
            prompt += "\n\nすでに使っている分類: " + knownCategories.prefix(20).joined(separator: "、")
                + "\n合うものがあればその言葉を使い、なければ新しい分類を付けてください。"
        }
        let session = LanguageModelSession(instructions: """
            あなたは保存された内容を整理する係です。渡された文章だけを根拠に、項目を埋めてください。\
            書かれていないことは推測しないでください。わからない項目は何も書かず空のままにしてください。\
            公式サイトやポータル、お知らせ、ニュースのページは article とし、何の公式サイトかは category に書いてください（アニメ、映画、音楽 など）。\
            work は本・映画・音楽などの作品1つを紹介したり販売したりするページだけ、event はチケットや参加を伴う催しそのもののページだけにしてください。
            """)
        do {
            let response = try await session.respond(to: prompt, generating: AIReading.self)
            return response.content
        } catch {
            return nil
        }
    }
}
