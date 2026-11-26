import SwiftUI
import SwiftData

/// 取り込んだもの全部。上にジャンルの絞り込み、検索は言葉で。
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var importer: Importer
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]

    @State private var genre: Genre?
    @State private var query = ""
    @State private var hits: [UUID]?
    @State private var showAdd = false
    @State private var addText = ""

    private var shown: [Item] {
        var list = items
        if let hits {
            let map = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            list = hits.compactMap { map[$0] }
        }
        if let genre { list = list.filter { $0.genre == genre } }
        return list
    }

    private var usedGenres: [Genre] {
        Genre.allCases.filter { g in items.contains { $0.genre == g } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    EmptyGuide()
                } else {
                    list
                }
            }
            .navigationTitle("ウィルシー")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addText = ""
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("URLを追加")
                }
            }
            .searchable(text: $query, prompt: "ことばで探す")
            .task(id: query) { await runSearch() }
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
            .navigationDestination(for: UUID.self) { id in
                if let item = items.first(where: { $0.id == id }) {
                    DetailView(item: item)
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    if shown.isEmpty {
                        Text(query.isEmpty ? "このジャンルにはまだありません" : "見つかりませんでした")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                    ForEach(shown) { item in
                        NavigationLink(value: item.id) {
                            ItemRow(item: item)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 104)
                    }
                } header: {
                    GenreBar(genres: usedGenres, selection: $genre)
                        .background(.background)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
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
                chip(title: "すべて", color: nil, selected: selection == nil) { selection = nil }
                ForEach(genres) { g in
                    chip(title: g.label, color: g.color, selected: selection == g) {
                        selection = (selection == g) ? nil : g
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private func chip(title: String, color: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
            .background(selected ? Color.primary : Color(.secondarySystemBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 一覧の1行。共有元・ジャンル・取り込み日が必ず見える。
struct ItemRow: View {
    let item: Item

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Thumbnail(item: item, size: 70)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Circle().fill(item.genre.color).frame(width: 8, height: 8)
                    Text(item.genre.label)
                    if !item.sourceName.isEmpty {
                        Text("・")
                        Text(item.sourceName).lineLimit(1)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if !item.analyzed {
                        Text("解析中")
                    } else {
                        Text(DateText.saved(item.createdAt))
                    }
                    if let date = item.eventDate {
                        Label(DateText.event(date), systemImage: "calendar")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.primary)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
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
