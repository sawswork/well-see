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

/// 画面の行き先。
enum Route: Hashable {
    case item(UUID)
    case map
    case schedule
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var importer: Importer

    var body: some View {
        HomeView()
            .onAppear { importer.refresh(context) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { importer.refresh(context) }
            }
    }
}
