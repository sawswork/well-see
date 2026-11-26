import SwiftUI
import SwiftData

/// 日付のあるものを、近い順に並べる。取り込んだ時点で自動的にここへ入る。
/// ジャンルは問わない（記事や動画でも、開催期間が書かれていれば並ぶ）。
struct ScheduleScreen: View {
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]

    private var dated: [Item] {
        items.filter { $0.eventDate != nil }
    }

    private var upcoming: [Item] {
        let floor = Calendar.current.startOfDay(for: Date())
        return dated
            .filter { ($0.eventLast ?? .distantPast) >= floor }
            .sorted { ($0.eventDate ?? .distantPast) < ($1.eventDate ?? .distantPast) }
    }

    private var past: [Item] {
        let floor = Calendar.current.startOfDay(for: Date())
        return dated
            .filter { ($0.eventLast ?? .distantPast) < floor }
            .sorted { ($0.eventLast ?? .distantPast) > ($1.eventLast ?? .distantPast) }
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
                    if !upcoming.isEmpty {
                        Section("これから") {
                            ForEach(upcoming) { item in row(item) }
                        }
                    }
                    if !past.isEmpty {
                        Section("終わったもの") {
                            ForEach(past) { item in row(item).opacity(0.6) }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("予定")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ item: Item) -> some View {
        NavigationLink(value: Route.item(item.id)) {
            HStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text(DateText.status(item.eventDate ?? Date(), item.eventEnd))
                        .font(.footnote.weight(.bold))
                    Circle().fill(item.genre.color).frame(width: 8, height: 8)
                }
                .frame(width: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text(DateText.span(item.eventDate ?? Date(), item.eventEnd))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let place = item.placeName ?? item.address, !place.isEmpty {
                        Text(place)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
