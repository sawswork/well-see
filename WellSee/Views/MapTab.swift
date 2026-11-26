import SwiftUI
import SwiftData
import MapKit

/// 場所のわかるものを地図に出す。ピンの色はジャンルの色。
struct MapTab: View {
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @State private var selection: UUID?
    @State private var position: MapCameraPosition = .automatic
    @State private var genre: Genre?

    private var located: [Item] {
        items.filter { $0.coordinate != nil }
    }

    private var pins: [Item] {
        guard let genre else { return located }
        return located.filter { $0.genre == genre }
    }

    private var usedGenres: [Genre] {
        Genre.allCases.filter { g in located.contains { $0.genre == g } }
    }

    private var selected: Item? {
        guard let selection else { return nil }
        return pins.first { $0.id == selection }
    }

    var body: some View {
        NavigationStack {
            Map(position: $position, selection: $selection) {
                ForEach(pins) { item in
                    Marker(item.placeName ?? item.displayTitle, systemImage: item.genre.symbol,
                           coordinate: item.coordinate ?? CLLocationCoordinate2D())
                        .tint(item.genre.color)
                        .tag(item.id)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if usedGenres.count > 1 {
                    GenreBar(genres: usedGenres, selection: $genre)
                        .background(.bar)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let item = selected {
                    NavigationLink(value: item.id) {
                        HStack(spacing: 0) {
                            ItemRow(item: item)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 18)
                        }
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if located.isEmpty {
                    ContentUnavailableView(
                        "地図に出せるものがありません",
                        systemImage: "map",
                        description: Text("お店や場所、イベントのページを取り込むと、ここにピンが立ちます。"))
                }
            }
            .navigationTitle("マップ")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                if let item = items.first(where: { $0.id == id }) {
                    DetailView(item: item)
                }
            }
            .onChange(of: genre) { _, _ in
                selection = nil
                position = .automatic
            }
        }
    }
}
