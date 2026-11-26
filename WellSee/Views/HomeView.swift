import SwiftUI
import SwiftData

/// ホーム。取り込んだもの全部が並ぶ。
/// 検索・絞り込み・地図・予定・追加は、親指の届く画面の下にまとめてある。
struct HomeView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var importer: Importer
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]

    @State private var path: [Route] = []
    @State private var genre: Genre?
    @State private var category: String?
    @State private var query = ""
    @State private var hits: [UUID]?
    @State private var showAdd = false
    @State private var addText = ""
    @FocusState private var searching: Bool

    private var shown: [Item] {
        var list: [Item]
        if let hits {
            let map = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            list = hits.compactMap { map[$0] }
        } else {
            // ピン留めしたものを上に。
            list = items.filter(\.pinned) + items.filter { !$0.pinned }
        }
        if let genre { list = list.filter { $0.genre == genre } }
        if let category { list = list.filter { $0.category == category } }
        return list
    }

    private var usedGenres: [Genre] {
        Genre.allCases.filter { g in items.contains { $0.genre == g } }
    }

    /// 選んでいるジャンルの中にある分類。
    private var categories: [String] {
        guard let genre else { return [] }
        var out: [String] = []
        for item in items where item.genre == genre && !item.category.isEmpty && !out.contains(item.category) {
            out.append(item.category)
        }
        return out
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if items.isEmpty {
                    EmptyGuide()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .task(id: query) { await runSearch() }
            .onChange(of: genre) { _, _ in category = nil }
            .alert("URLを追加", isPresented: $showAdd) {
                TextField("https://", text: $addText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("追加") { importer.add(urlString: addText, context: context) }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("ふだんは、ほかのアプリの共有ボタンから「ウィルシー」を選ぶだけで入ります。")
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .item(let id):
                    if let item = items.first(where: { $0.id == id }) {
                        DetailView(item: item)
                    }
                case .map:
                    MapScreen()
                case .schedule:
                    ScheduleScreen()
                }
            }
        }
    }

    /// 絞り込みも検索もしていないとき。
    private var browsing: Bool {
        genre == nil && category == nil && hits == nil
    }

    /// これからの予定（近い順）。
    private var upcoming: [Item] {
        let floor = Calendar.current.startOfDay(for: Date())
        return items
            .filter { ($0.eventLast ?? .distantPast) >= floor && $0.eventDate != nil }
            .sorted { ($0.eventDate ?? .distantPast) < ($1.eventDate ?? .distantPast) }
    }

    private var list: some View {
        List {
            // いちばん上：ジャンルごとの件数。押すとそのジャンルだけになる。
            GenreTiles(genres: usedGenres, counts: counts, selection: $genre)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)

            if browsing {
                if !upcoming.isEmpty {
                    Section {
                        ForEach(upcoming.prefix(3)) { item in cardRow(item, showGenre: true) }
                        if upcoming.count > 3 {
                            moreRow("予定をすべて見る（\(upcoming.count)件）") { path.append(.schedule) }
                        }
                    } header: {
                        sectionHeader("これからの予定", systemImage: "calendar", color: .pink)
                    }
                }
                let pinned = items.filter(\.pinned)
                if !pinned.isEmpty {
                    Section {
                        ForEach(pinned) { item in cardRow(item, showGenre: true) }
                    } header: {
                        sectionHeader("ピン留め", systemImage: "pin.fill", color: .orange)
                    }
                }
                ForEach(usedGenres) { g in
                    let group = items.filter { $0.genre == g }
                    Section {
                        if g == .place {
                            // 場所は横に並べて、めくって見る。
                            carousel(group)
                        } else {
                            ForEach(group.prefix(3)) { item in cardRow(item, showGenre: false) }
                        }
                        if group.count > 3 {
                            moreRow("\(g.label)をすべて見る（\(group.count)件）") { genre = g }
                        }
                    } header: {
                        sectionHeader(g.label, systemImage: g.symbol, color: g.color)
                    }
                }
            } else {
                if shown.isEmpty {
                    Text(query.isEmpty ? "ここにはまだありません" : "見つかりませんでした")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                        .listRowSeparator(.hidden)
                }
                ForEach(shown) { item in cardRow(item, showGenre: genre == nil) }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    private var counts: [Genre: Int] {
        var out: [Genre: Int] = [:]
        for item in items { out[item.genre, default: 0] += 1 }
        return out
    }

    private func open(_ item: Item) {
        searching = false
        path.append(.item(item.id))
    }

    private func togglePin(_ item: Item) {
        item.pinned.toggle()
        try? context.save()
    }

    private func remove(_ item: Item) {
        context.delete(item)
        try? context.save()
    }

    /// カード1枚の行。右へスワイプでピン留め、左へスワイプで削除。
    private func cardRow(_ item: Item, showGenre: Bool) -> some View {
        Button {
            open(item)
        } label: {
            ItemCard(item: item, showGenre: showGenre)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
        .listRowSeparator(.hidden)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                togglePin(item)
            } label: {
                Label(item.pinned ? "ピンを外す" : "ピン留め", systemImage: item.pinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                remove(item)
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    /// 横に並べたカード。横スクロールとぶつかるので、ピン留めと削除は長押しのメニューから。
    private func carousel(_ group: [Item]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(group.prefix(12)) { item in
                    Button {
                        open(item)
                    } label: {
                        ItemCard(item: item, showGenre: false)
                            .frame(width: 300)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            togglePin(item)
                        } label: {
                            Label(item.pinned ? "ピンを外す" : "ピン留め", systemImage: item.pinned ? "pin.slash" : "pin")
                        }
                        Button(role: .destructive) {
                            remove(item)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    private func sectionHeader(_ title: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(title)
                .foregroundStyle(.primary)
        }
        .font(.title3.weight(.bold))
        .textCase(nil)
        .padding(.top, 6)
        .accessibilityAddTraits(.isHeader)
    }

    private func moreRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 18))
        .listRowSeparator(.hidden)
    }

    /// 画面の下：分類 → ジャンル → 検索欄と3つのボタン。
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            if !categories.isEmpty {
                ChipBar(titles: categories, selection: $category)
            }
            if !usedGenres.isEmpty {
                GenreBar(genres: usedGenres, selection: $genre)
            }
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("ことばで探す", text: $query)
                        .focused($searching)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("検索語を消す")
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(height: 48)
                .background(Color(.secondarySystemBackground), in: Capsule())

                if !searching {
                    iconButton("map", label: "マップ") { path.append(.map) }
                    iconButton("calendar", label: "予定") { path.append(.schedule) }
                    iconButton("plus", label: "URLを追加") {
                        addText = ""
                        showAdd = true
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, usedGenres.isEmpty ? 10 : 2)
            .padding(.bottom, 8)
        }
        .background(.bar)
        .animation(.easeOut(duration: 0.15), value: searching)
    }

    private func iconButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 48, height: 48)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            hits = nil
            return
        }
        // 打っている途中は待つ。
        try? await Task.sleep(nanoseconds: 180_000_000)
        if Task.isCancelled { return }
        let result = await SearchEngine.search(q, in: items)
        if !Task.isCancelled { hits = result }
    }
}

/// ジャンルの絞り込み。1タップで切り替わる。
struct GenreBar: View {
    let genres: [Genre]
    @Binding var selection: Genre?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "すべて", color: nil, selected: selection == nil) { selection = nil }
                ForEach(genres) { g in
                    Chip(title: g.label, color: g.color, selected: selection == g) {
                        selection = (selection == g) ? nil : g
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

/// 分類の絞り込み（ジャンルを選んだときだけ出る）。
struct ChipBar: View {
    let titles: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(titles, id: \.self) { title in
                    Chip(title: title, color: nil, selected: selection == title, small: true) {
                        selection = (selection == title) ? nil : title
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}

struct Chip: View {
    let title: String
    let color: Color?
    let selected: Bool
    var small = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(title)
                    .font((small ? Font.footnote : Font.subheadline).weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, small ? 12 : 14)
            .frame(minHeight: small ? 32 : 36)
            .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
            .background(selected ? Color.primary : Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// いちばん上に並ぶ、ジャンルごとのタイル（記号・名前・件数）。
struct GenreTiles: View {
    let genres: [Genre]
    let counts: [Genre: Int]
    @Binding var selection: Genre?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(genres) { g in
                    let selected = selection == g
                    Button {
                        selection = selected ? nil : g
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: g.symbol)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(g.color)
                                .frame(height: 24)
                            Text(g.label)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("\(counts[g] ?? 0)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 78, height: 86)
                        .background(g.color.opacity(selected ? 0.32 : 0.13),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(g.color.opacity(selected ? 1 : 0.6), lineWidth: selected ? 2 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(g.label) \(counts[g] ?? 0)件")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }
}

/// ホームに並ぶカード。ふちの色がジャンルの色。
/// 並びはどれも同じ：題名 ／ ジャンル・分類・共有元 ／ 取り込み日（右に予定）。
struct ItemCard: View {
    let item: Item
    var showGenre = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(item: item, size: 78)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 6) {
                    Text(item.displayTitle)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if item.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("ピン留め")
                    }
                    if showGenre {
                        Text(item.genre.label)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(item.genre.color.opacity(0.28), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Circle().fill(item.genre.color).frame(width: 8, height: 8)
                    Text(item.sourceName.isEmpty ? item.genreText : item.genreText + " ・ " + item.sourceName)
                        .lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Text(item.analyzed ? DateText.saved(item.createdAt) : "解析中")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let date = item.eventDate {
                        Label(DateText.span(date, item.eventEnd), systemImage: "calendar")
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(Color(.tertiarySystemBackground), in: Capsule())
                    }
                }
                .font(.footnote)
            }
            .frame(minHeight: 78)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(item.genre.color.opacity(0.55), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// 一覧の1行。どの項目も同じ並び：題名 ／ ジャンル・分類・共有元 ／ 取り込み日（と予定）。
struct ItemRow: View {
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Thumbnail(item: item, size: 72)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Circle().fill(item.genre.color).frame(width: 8, height: 8)
                    Text(item.sourceName.isEmpty ? item.genreText : item.genreText + " ・ " + item.sourceName)
                        .lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(item.analyzed ? DateText.saved(item.createdAt) : "解析中")
                    if let date = item.eventDate {
                        Label(DateText.span(date, item.eventEnd), systemImage: "calendar")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("ピン留め")
            }
        }
        .contentShape(Rectangle())
    }
}

/// サムネイル。画像がなければジャンルの色と記号。
struct Thumbnail: View {
    let item: Item
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(item.genre.color.opacity(0.16))
            if let image = Thumbnails.image(for: item) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.genre.symbol)
                    .font(.system(size: size * 0.36, weight: .medium))
                    .foregroundStyle(item.genre.color)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// 画像の読み込みを使い回す。
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSUUID, UIImage>()

    static func image(for item: Item) -> UIImage? {
        let key = item.id as NSUUID
        if let hit = cache.object(forKey: key) { return hit }
        guard let data = item.imageData, let image = UIImage(data: data) else { return nil }
        let small = image.preparingThumbnail(of: CGSize(width: 240, height: 240 * image.size.height / max(image.size.width, 1))) ?? image
        cache.setObject(small, forKey: key)
        return small
    }

    static func forget(_ id: UUID) {
        cache.removeObject(forKey: id as NSUUID)
    }
}

/// 何も入っていないときの案内。
struct EmptyGuide: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("まだ何もありません")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                step("1", "Safari や YouTube、Instagram などで共有ボタンを押す")
                step("2", "一覧から「ウィルシー」を選ぶ")
                step("3", "ここに入り、ジャンルや場所・日付が自動で付く")
            }
            Text("共有先に見当たらないときは、アプリの並びの右端「その他」から追加できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 460)
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number)
                .font(.footnote.weight(.bold))
                .frame(width: 24, height: 24)
                .background(Color(.secondarySystemBackground), in: Circle())
            Text(text)
                .font(.subheadline)
        }
    }
}
