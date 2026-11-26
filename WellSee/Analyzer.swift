import Foundation
import UIKit
import Vision
import MapKit
import FoundationModels

/// 解析の結果。
struct Reading {
    var genre: Genre = .article
    var title = ""
    var summary = ""
    var sourceName = ""
    var bodyText = ""
    var placeName: String?
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var eventDate: Date?
    /// ページから取ったサムネイル。
    var thumbnail: Data?
    /// ページが読めたか（通信できなかったら false。あとでやり直す）。
    var reachedPage = true
}

/// 端末内AIに読ませる形。文字だけにしてある（空文字は「なし」）。
@Generable
struct AIReading {
    @Guide(description: "ジャンル。place, product, event, recipe, work, article, video, image, memo, document のどれか1つ")
    var genre: String
    @Guide(description: "内容を表す短い題名")
    var title: String
    @Guide(description: "内容の要約。日本語で1〜2文")
    var summary: String
    @Guide(description: "お店や場所の名前。なければ空文字")
    var placeName: String
    @Guide(description: "住所。本文に書かれていなければ空文字")
    var address: String
    @Guide(description: "イベントなどの開催日。yyyy-MM-dd 形式。書かれていなければ空文字")
    var date: String
}

/// 取り込んだものを読んで、共有元・ジャンル・場所・日付などを取り出す。
/// 1. ページに埋め込まれた情報（確実）　2. サイトごとの決まり　3. 端末内AI（足りないところだけ）の順に使う。
enum Analyzer {
    static func read(url: URL?, text: String?, image: Data?) async -> Reading {
        var r = Reading()
        var ruleGenre: Genre?
        var fallback: Genre = .article
        var corpus = ""
        var description = ""

        if let url {
            let host = (url.host ?? "").lowercased()
            r.sourceName = Sites.name(for: host) ?? host.replacingOccurrences(of: "www.", with: "")
            ruleGenre = Sites.genre(for: host)
            if let page = await Web.fetch(url) {
                let meta = Web.metaTags(page.html)
                let nodes = Web.jsonLD(page.html)
                r.title = meta["og:title"] ?? Web.title(page.html) ?? ""
                description = meta["og:description"] ?? meta["description"] ?? ""
                if Sites.name(for: host) == nil, let site = meta["og:site_name"], !site.isEmpty {
                    r.sourceName = site
                }
                if let g = Structured.apply(nodes, to: &r) { ruleGenre = g }
                if ruleGenre == nil { ruleGenre = Sites.genre(forOGType: meta["og:type"]) }
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
                corpus = [r.title, description, Web.plainText(page.html)].joined(separator: "\n")
                if let img = meta["og:image"], let imageURL = URL(string: img, relativeTo: page.finalURL) {
                    r.thumbnail = await Web.downloadImage(imageURL.absoluteURL)
                }
            } else {
                r.reachedPage = false
            }
            if let text, !text.isEmpty { corpus += "\n" + text }
            r.title = Web.cleanTitle(r.title, site: r.sourceName)
            if r.title.isEmpty {
                r.title = firstLine(text) ?? host
            }
        } else if let image {
            r.sourceName = "写真・画像"
            fallback = .image
            if let cg = UIImage(data: image)?.cgImage {
                corpus = await Eyes.readText(cg)
            }
            if let text, !text.isEmpty { corpus = text + "\n" + corpus }
            r.title = firstLine(corpus) ?? "画像"
        } else if let text {
            r.sourceName = "テキスト"
            fallback = .memo
            corpus = text
            r.title = firstLine(text) ?? "メモ"
        }

        r.bodyText = String(corpus.prefix(4000))
        r.summary = String(description.prefix(160))

        // 端末内AI。使えない端末では何もしない。
        let ai = await Brain.read(title: r.title, text: r.bodyText)
        if let ai {
            if !ai.summary.isEmpty { r.summary = ai.summary }
            if url == nil, !ai.title.isEmpty { r.title = ai.title }
        }
        r.genre = ruleGenre ?? ai.flatMap { Genre(rawValue: $0.genre) } ?? fallback

        if r.genre == .place || r.genre == .event {
            if r.placeName == nil, let p = ai?.placeName, !p.isEmpty { r.placeName = p }
            if r.address == nil, let a = ai?.address, !a.isEmpty { r.address = a }
            if r.genre == .place, r.placeName == nil { r.placeName = r.title }
        }
        if r.genre == .event, r.eventDate == nil {
            if let d = ai?.date, let parsed = Dates.parse(d) {
                r.eventDate = parsed
            } else {
                r.eventDate = Dates.firstUpcoming(in: r.bodyText)
            }
        }

        // 地図に出すための座標。場所とイベントだけ調べる。
        if r.latitude == nil, r.genre == .place || r.genre == .event {
            let query = r.address ?? r.placeName ?? ""
            if !query.isEmpty, let c = await Eyes.locate(query) {
                r.latitude = c.latitude
                r.longitude = c.longitude
            }
        }
        return r
    }

    private static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(40)) }
        }
        return nil
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
        if type.hasPrefix("article") { return .article }
        return nil
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
        for node in nodes {
            let types = typeNames(node)
            if types.contains(where: { $0.hasSuffix("Event") }) {
                take(.event)
                if r.eventDate == nil, let s = node["startDate"] as? String { r.eventDate = Dates.parse(s) }
                if let location = node["location"] as? [String: Any] {
                    if r.placeName == nil { r.placeName = location["name"] as? String }
                    readPlace(location, into: &r)
                }
            } else if types.contains(where: { placeTypes.contains($0) }) {
                take(.place)
                if r.placeName == nil { r.placeName = node["name"] as? String }
                readPlace(node, into: &r)
            } else if types.contains("Recipe") {
                take(.recipe)
            } else if types.contains("Product") {
                take(.product)
            } else if types.contains(where: { workTypes.contains($0) }) {
                take(.work)
            } else if types.contains("VideoObject") {
                take(.video)
            } else if types.contains(where: { articleTypes.contains($0) }) {
                take(.article)
            }
        }
        return found
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
}

// MARK: - ページの取得と読み取り

enum Web {
    static func fetch(_ url: URL) async -> (html: String, finalURL: URL)? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        request.setValue("ja,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let head = Data(data.prefix(1_500_000))
        let html = String(data: head, encoding: .utf8)
            ?? String(data: head, encoding: .shiftJIS)
            ?? String(data: head, encoding: .japaneseEUC)
            ?? String(decoding: head, as: UTF8.self)
        return (html, response.url ?? url)
    }

    static func downloadImage(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request), data.count < 12_000_000 else {
            return nil
        }
        return ImageTools.jpeg(from: data, maxPixel: 900)
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

    /// 本文の文字だけを取り出す。
    static func plainText(_ html: String) -> String {
        guard let strip = try? NSRegularExpression(
            pattern: "<(script|style|noscript|svg|header|footer|nav)\\b.*?</\\1>|<[^>]+>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return "" }
        let ns = html as NSString
        var text = strip.stringByReplacingMatches(in: html, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: " ")
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

    /// 「店名 | サイト名」の後ろを落とす。
    static func cleanTitle(_ title: String, site: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !site.isEmpty else { return t }
        for separator in [" | ", " - ", " ｜ ", "｜", " – ", " — "] {
            if let range = t.range(of: separator, options: .backwards) {
                let tail = t[range.upperBound...]
                if tail.localizedCaseInsensitiveContains(site), t.distance(from: t.startIndex, to: range.lowerBound) >= 2 {
                    t = String(t[..<range.lowerBound])
                }
            }
        }
        return t
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

    /// 文章の中で最初に出てくる、これから先の日付。
    static func firstUpcoming(in text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let head = String(text.prefix(1500))
        let floor = Calendar.current.startOfDay(for: Date())
        for match in detector.matches(in: head, options: [], range: NSRange(head.startIndex..., in: head)) {
            if let date = match.date, date >= floor { return date }
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

    static func locate(_ query: String) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        return response.mapItems.first?.placemark.coordinate
    }
}

// MARK: - 端末内AI

enum Brain {
    static func read(title: String, text: String) async -> AIReading? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let body = String(text.prefix(1200))
        guard !(title.isEmpty && body.isEmpty) else { return nil }
        let session = LanguageModelSession(instructions: """
            あなたは保存された内容を整理する係です。渡された題名と本文だけを根拠に、項目を埋めてください。\
            本文に書かれていないことは推測せず、空文字にしてください。
            """)
        do {
            let response = try await session.respond(to: "題名: \(title)\n本文: \(body)", generating: AIReading.self)
            return response.content
        } catch {
            return nil
        }
    }
}
