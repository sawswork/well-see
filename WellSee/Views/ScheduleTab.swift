import SwiftUI
import SwiftData

/// 日付のあるものを、近い順に並べる。取り込んだ時点で自動的にここへ入る。
/// ジャンルは問わない（記事や動画でも、開催期間が書かれていれば並ぶ）。
struct ScheduleScreen: View {
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]

    private var dated: [Item] {
        items.filter { $0.eventDate != nil }
    }

    /// いま開催中のもの（期間の途中）。終わりが近い順。
    private var ongoing: [Item] {
        dated.filter { Self.phase($0) == .ongoing }
            .sorted { ($0.eventLast ?? .distantFuture) < ($1.eventLast ?? .distantFuture) }
    }

    private var upcoming: [Item] {
        dated.filter { Self.phase($0) == .upcoming }
            .sorted { ($0.eventDate ?? .distantPast) < ($1.eventDate ?? .distantPast) }
    }

    private var past: [Item] {
        dated.filter { Self.phase($0) == .past }
            .sorted { ($0.eventLast ?? .distantPast) > ($1.eventLast ?? .distantPast) }
    }

    enum Phase { case ongoing, upcoming, past }

    static func phase(_ item: Item) -> Phase {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = item.eventDate else { return .past }
        let last = item.eventLast ?? start
        if cal.startOfDay(for: last) < today { return .past }
        if cal.startOfDay(for: start) <= today { return .ongoing }
        return .upcoming
    }

    var body: some View {
        Group {
            if dated.isEmpty {
                ContentUnavailableView(
                    "予定はまだありません",
                    systemImage: "calendar",
                    description: Text("開催日や期間の書かれたものを取り込むと、ここに並びます。"))
            } else {
                List {
                    section("開催中", ongoing)
                    section("これから", upcoming)
                    section("終わったもの", past)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("予定")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func section(_ title: String, _ group: [Item]) -> some View {
        if !group.isEmpty {
            Section {
                ForEach(group) { item in
                    NavigationLink(value: Route.item(item.id)) {
                        ScheduleCard(item: item, phase: Self.phase(item))
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    .listRowSeparator(.hidden)
                }
            } header: {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color(.label))
                    .textCase(nil)
            }
        }
    }
}

/// 予定の1件。サムネイル、状態（開催中・あと3日・終了）、題名、期間、場所。
struct ScheduleCard: View {
    let item: Item
    let phase: ScheduleScreen.Phase

    private var badge: String {
        guard let start = item.eventDate else { return "" }
        switch phase {
        case .ongoing:
            // 1日だけの予定なら「今日」。期間なら「開催中」と残り日数。
            guard let end = item.eventEnd, !Calendar.current.isDate(start, inSameDayAs: end) else { return "今日" }
            let cal = Calendar.current
            let left = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: end)).day ?? 0
            return left == 0 ? "開催中・今日まで" : "開催中・あと\(left)日"
        case .upcoming:
            return DateText.remaining(start)
        case .past:
            return "終了"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(item: item, size: 78)
            VStack(alignment: .leading, spacing: 5) {
                Text(badge)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .foregroundStyle(phase == .ongoing ? Color.white : Color(.label))
                    .background(phase == .ongoing ? Color.pink : Color(.tertiarySystemFill), in: Capsule())
                Text(item.displayTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Label(DateText.span(item.eventDate ?? Date(), item.eventEnd), systemImage: "calendar")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let place = item.placeName ?? item.address, !place.isEmpty {
                    Label(place, systemImage: "mappin")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .opacity(phase == .past ? 0.55 : 1)
        .padding(.vertical, 2)
    }
}
