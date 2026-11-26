import SwiftUI
import SwiftData
import MapKit

/// 1件の中身。
struct DetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Bindable var item: Item

    @State private var confirmDelete = false
    @State private var calendarFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let data = item.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Menu {
                        ForEach(Genre.allCases) { g in
                            Button {
                                item.genre = g
                            } label: {
                                Label(g.label, systemImage: g.symbol)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(item.genre.color).frame(width: 9, height: 9)
                            Text(item.genre.label)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(minHeight: 32)
                    }
                    .accessibilityLabel("ジャンルを変更。いまは\(item.genre.label)")

                    Text(item.displayTitle)
                        .font(.title2.weight(.bold))
                        .textSelection(.enabled)
                    if !item.summary.isEmpty {
                        Text(item.summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                actions

                VStack(spacing: 0) {
                    row("共有元", item.sourceName.isEmpty ? "不明" : item.sourceName)
                    row("取り込み日", DateText.saved(item.createdAt))
                    if let date = item.eventDate {
                        row("日付", DateText.event(date) + "（" + DateText.remaining(date) + "）")
                    }
                    if let place = item.placeName, !place.isEmpty, place != item.title {
                        row("場所", place)
                    }
                    if let address = item.address, !address.isEmpty {
                        row("住所", address)
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let coordinate = item.coordinate {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: coordinate, latitudinalMeters: 900, longitudinalMeters: 900))) {
                        Marker(item.placeName ?? item.displayTitle, systemImage: item.genre.symbol, coordinate: coordinate)
                            .tint(item.genre.color)
                    }
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .allowsHitTesting(false)
                }

                if let text = item.rawText, !text.isEmpty, item.url == nil {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let url = item.url {
                        ShareLink(item: url) { Label("共有", systemImage: "square.and.arrow.up") }
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("その他")
            }
        }
        .confirmationDialog("この項目を削除しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                context.delete(item)
                try? context.save()
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("カレンダーに登録できませんでした", isPresented: $calendarFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("設定アプリでカレンダーへの追加を許可してください。")
        }
    }

    @ViewBuilder
    private var actions: some View {
        let hasAny = item.url != nil || item.coordinate != nil || item.eventDate != nil
        if hasAny {
            VStack(spacing: 10) {
                if let url = item.url {
                    bigButton("元のページを開く", systemImage: "safari", prominent: true) {
                        openURL(url)
                    }
                }
                if let coordinate = item.coordinate {
                    bigButton("経路を見る", systemImage: "arrow.triangle.turn.up.right.diamond", prominent: item.url == nil) {
                        let name = (item.placeName ?? item.displayTitle)
                            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let maps = URL(string: "http://maps.apple.com/?daddr=\(coordinate.latitude),\(coordinate.longitude)&q=\(name)") {
                            openURL(maps)
                        }
                    }
                }
                if item.eventDate != nil {
                    bigButton(item.calendarAdded ? "カレンダーに登録済み" : "カレンダーに登録",
                              systemImage: item.calendarAdded ? "checkmark" : "calendar.badge.plus",
                              prominent: false) {
                        Task {
                            if await CalendarWriter.add(item) {
                                item.calendarAdded = true
                                try? context.save()
                            } else {
                                calendarFailed = true
                            }
                        }
                    }
                    .disabled(item.calendarAdded)
                }
            }
        }
    }

    private func bigButton(_ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(prominent ? Color(.systemBackground) : Color.primary)
                .background(prominent ? Color.primary : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 16)
        }
    }
}
