import SwiftUI
import SwiftData

@main
struct WellSeeApp: App {
    @StateObject private var importer = Importer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(importer)
        }
        .modelContainer(for: Item.self)
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var importer: Importer

    var body: some View {
        TabView {
            Tab("すべて", systemImage: "square.grid.2x2") {
                LibraryView()
            }
            Tab("マップ", systemImage: "map") {
                MapTab()
            }
            Tab("予定", systemImage: "calendar") {
                ScheduleTab()
            }
        }
        .onAppear { importer.refresh(context) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { importer.refresh(context) }
        }
    }
}
