import SwiftUI
import SwiftData
import MapKit

/// 場所のわかるものを地図に出す。ピンの色はジャンルの色。
struct MapScreen: View {
    @Query(sort: \Item.createdAt, order: .reverse) private var items: [Item]
    @State private var selection: UUID?
    /// 最初は現在地のまわり。位置情報が使えないときは日本全体（海外で使っているときはピンが全部入る範囲）。
    @State private var position: MapCameraPosition = .userLocation(fallback: MapScreen.wide)
    @State private var locationManager = CLLocationManager()

    private static var wide: MapCameraPosition {
        guard Locale.current.region?.identifier == "JP" else { return .automatic }
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.6, longitude: 137.6),
            span: MKCoordinateSpan(latitudeDelta: 17, longitudeDelta: 19)))
    }
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
        Map(position: $position, selection: $selection) {
            ForEach(pins) { item in
                Marker(item.placeName ?? item.displayTitle, systemImage: item.genre.symbol,
                       coordinate: item.coordinate ?? CLLocationCoordinate2D())
                    .tint(item.genre.color)
                    .tag(item.id)
            }
            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onAppear {
            // 初めて開いたときだけ、位置情報を使ってよいか尋ねる。
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let item = selected {
                    NavigationLink(value: Route.item(item.id)) {
                        HStack(spacing: 0) {
                            ItemRow(item: item)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                    .buttonStyle(.plain)
                }
                // 戻るボタンは左下。ジャンルがあればその右に並べる。
                HStack(spacing: 0) {
                    BackButton()
                        .padding(.leading, 12)
                    if usedGenres.count > 1 {
                        GenreBar(genres: usedGenres, selection: $genre)
                    } else {
                        Spacer(minLength: 0)
                    }
                }
                .padding(.bottom, 6)
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
        .navigationBarBackButtonHidden(true)
        .onChange(of: genre) { _, _ in
            selection = nil
        }
    }
}
