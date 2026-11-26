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
    @State private var confirmCalendar = false
    @State private var chooseMap = false

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
                            Text(item.genreText)
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
                    if !item.pointList.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(item.pointList, id: \.self) { point in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("・").foregroundStyle(item.genre.color)
                                    Text(point)
                                }
                                .font(.subheadline)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                actions

                // 情報の並びは、どの項目でも同じ：共有元 → 日付 → 場所 → その内容ならではの項目 → 取り込み日
                VStack(spacing: 0) {
                    row("共有元", item.sourceName.isEmpty ? "不明" : item.sourceName)
                    if let date = item.eventDate {
                        row("日付", DateText.span(date, item.eventEnd) + "（" + DateText.status(date, item.eventEnd) + "）")
                    }
                    if let place = item.placeName, !place.isEmpty, place != item.title {
                        row("場所", place)
                    }
                    if let address = item.address, !address.isEmpty {
                        row("住所", address)
                    }
                    ForEach(item.details, id: \.self) { detail in
                        row(detail.label, detail.value)
                    }
                    row("取り込み日", DateText.saved(item.createdAt))
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
        .confirmationDialog("すでに一度登録しています。もう一度登録しますか？", isPresented: $confirmCalendar, titleVisibility: .visible) {
            Button("もう一度登録") { addToCalendar() }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog("どのアプリで経路を見ますか？", isPresented: $chooseMap, titleVisibility: .visible) {
            Button("マップ") { Routes.openAppleMaps(item) }
            Button("Googleマップ") { Routes.openGoogleMaps(item) }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("カレンダーに登録できませんでした", isPresented: $calendarFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("設定アプリでカレンダーへの追加を許可してください。")
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if let url = item.url {
                bigButton("元のページを開く", systemImage: "safari", prominent: true, enabled: true) {
                    openURL(url)
                }
            }
            // 場所がわからないものは押せない（灰色）。
            bigButton("経路を見る", systemImage: "arrow.triangle.turn.up.right.diamond",
                      prominent: item.url == nil, enabled: item.coordinate != nil) {
                if Routes.hasGoogleMaps {
                    chooseMap = true
                } else {
                    Routes.openAppleMaps(item)
                }
            }
            if item.eventDate != nil {
                // カレンダー側で消されたかどうかはアプリからは見えないので、何度でも登録できるようにしておく。
                bigButton(item.calendarAdded ? "カレンダーにもう一度登録" : "カレンダーに登録",
                          systemImage: "calendar.badge.plus", prominent: false, enabled: true) {
                    if item.calendarAdded {
                        confirmCalendar = true
                    } else {
                        addToCalendar()
                    }
                }
            }
        }
    }

    private func addToCalendar() {
        Task {
            if await CalendarWriter.add(item) {
                item.calendarAdded = true
                try? context.save()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else {
                calendarFailed = true
            }
        }
    }

    private func bigButton(_ title: String, systemImage: String, prominent: Bool, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(prominent ? Color(.systemBackground) : Color(.label))
                .background(prominent ? Color(.label) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
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

/// 経路を地図アプリで開く。ブラウザは開かない。
@MainActor
enum Routes {
    /// Googleマップのアプリが入っているか。
    static var hasGoogleMaps: Bool {
        guard let url = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    static func openAppleMaps(_ item: Item) {
        guard let coordinate = item.coordinate else { return }
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = item.placeName ?? item.displayTitle
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }

    static func openGoogleMaps(_ item: Item) {
        guard let coordinate = item.coordinate,
              let url = URL(string: "comgooglemaps://?daddr=\(coordinate.latitude),\(coordinate.longitude)") else { return }
        UIApplication.shared.open(url)
    }
}
