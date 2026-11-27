import Foundation
import SwiftData
import EventKit

/// 共有シートから届いたものを取り込み、順番に解析する。
@MainActor
final class Importer: ObservableObject {
    /// 解析待ちの件数（画面の「解析中」表示用）。
    @Published private(set) var pending = 0

    private var queue: [UUID] = []
    private var running = false

    /// アプリを開いたとき・前面に戻ったときに呼ぶ。
    func refresh(_ context: ModelContext) {
        for entry in Inbox.readAll() {
            add(url: entry.item.url, text: entry.item.text, image: entry.image,
                latitude: entry.item.latitude, longitude: entry.item.longitude,
                date: entry.item.date, context: context)
            Inbox.remove(entry.item)
        }
        // 前回、通信できずに終わったものをやり直す。
        let all = (try? context.fetch(FetchDescriptor<Item>())) ?? []
        for item in all where !queue.contains(item.id) {
            if !item.analyzed && item.attempts < 4 {
                queue.append(item.id)
            } else if item.analysisVersion < Item.currentAnalysisVersion {
                // 解析のしくみが新しくなったので、読み直す。
                item.attempts = 0
                queue.append(item.id)
            }
        }
        try? context.save()
        run(context)
    }

    /// アプリ内から URL を足す。
    func add(urlString: String, context: ModelContext) {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard URL(string: s)?.host != nil else { return }
        add(url: s, text: nil, image: nil, latitude: nil, longitude: nil, date: Date(), context: context)
        try? context.save()
        run(context)
    }

    /// メモなどを書き換えたあとに呼ぶ。保存して、検索用のベクトルを作り直す。
    func contentChanged(_ item: Item, context: ModelContext) {
        try? context.save()
        SearchEngine.forget(item.id)
        Task {
            if let vector = await Embedder.shared.vector(for: item.embeddingText) {
                item.embedding = VectorCodec.data(vector)
                SearchEngine.forget(item.id)
                try? context.save()
            }
        }
    }

    private func add(url: String?, text: String?, image: Data?, latitude: Double?, longitude: Double?,
                     date: Date, context: ModelContext) {
        // 同じ URL は二重に登録せず、いちばん上に戻すだけ。
        if let url {
            let all = (try? context.fetch(FetchDescriptor<Item>())) ?? []
            if let existing = all.first(where: { $0.urlString == url }) {
                existing.createdAt = date
                return
            }
        }
        let item = Item(urlString: url, rawText: text, imageData: url == nil ? image : nil,
                        isOwnImage: url == nil && image != nil, createdAt: date)
        item.latitude = latitude
        item.longitude = longitude
        context.insert(item)
        queue.append(item.id)
    }

    private func run(_ context: ModelContext) {
        pending = queue.count
        guard !running, !queue.isEmpty else { return }
        running = true
        Task {
            await Embedder.shared.prepare()
            while !queue.isEmpty {
                let id = queue.removeFirst()
                let all = (try? context.fetch(FetchDescriptor<Item>())) ?? []
                if let item = all.first(where: { $0.id == id }) {
                    // 分類の言葉がばらつかないよう、すでに使っている分類を渡す。
                    var known: [String] = []
                    for other in all where !other.category.isEmpty && !known.contains(other.category) {
                        known.append(other.category)
                    }
                    await analyze(item, knownCategories: known)
                    try? context.save()
                }
                pending = queue.count
            }
            running = false
        }
    }

    private func analyze(_ item: Item, knownCategories: [String]) async {
        item.attempts += 1
        let reading = await Analyzer.read(url: item.url, text: item.rawText,
                                          image: item.isOwnImage ? item.imageData : nil,
                                          knownCategories: knownCategories)
        // 通信できなかったときは、前に読めた内容を消さない。
        if !reading.reachedPage, item.analysisVersion > 0 { return }
        item.title = reading.title
        item.summary = reading.summary
        item.genre = reading.genre
        item.sourceName = reading.sourceName
        item.bodyText = reading.bodyText
        item.placeName = reading.placeName
        item.address = reading.address
        if let lat = reading.latitude, let lon = reading.longitude {
            item.latitude = lat
            item.longitude = lon
        } else if !item.isOwnImage {
            // 場所が見つからなかったら、前の解析で付いた座標は消す（写真の撮影場所は残す）。
            item.latitude = nil
            item.longitude = nil
        }
        item.eventDate = reading.eventStart
        item.eventEnd = reading.eventEnd
        item.category = reading.category
        item.keywords = reading.keywords.joined(separator: "、")
        item.points = reading.points.joined(separator: "\n")
        item.author = reading.author
        item.details = reading.details
        if !item.isOwnImage, let thumbnail = reading.thumbnail {
            item.imageData = thumbnail
        }
        if let vector = await Embedder.shared.vector(for: item.embeddingText) {
            item.embedding = VectorCodec.data(vector)
        }
        SearchEngine.forget(item.id)
        Thumbnails.forget(item.id)
        // 通信できなかったときは、次に開いたときにやり直す。
        item.analyzed = reading.reachedPage || item.attempts >= 4
        if reading.reachedPage { item.analysisVersion = Item.currentAnalysisVersion }
    }
}

/// iPhone のカレンダーへ登録する（書き込みだけの許可を使う）。
@MainActor
enum CalendarWriter {
    static func add(_ item: Item) async -> Bool {
        guard let date = item.eventDate else { return false }
        let store = EKEventStore()
        guard (try? await store.requestWriteOnlyAccessToEvents()) == true else { return false }
        let event = EKEvent(eventStore: store)
        event.title = item.displayTitle
        event.startDate = date
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        if let end = item.eventEnd, end > date {
            event.isAllDay = true
            event.endDate = end
        } else if comps.hour == 0 && comps.minute == 0 {
            event.isAllDay = true
            event.endDate = date
        } else {
            event.endDate = date.addingTimeInterval(3600)
        }
        event.location = item.address ?? item.placeName
        event.url = item.url
        event.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(event, span: .thisEvent)
            return true
        } catch {
            return false
        }
    }
}
