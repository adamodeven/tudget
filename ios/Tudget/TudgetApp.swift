import SwiftUI
import SwiftData

@main
struct TudgetApp: App {

    @State private var settings = AppSettings.shared
    private let container: ModelContainer

    init() {
        let schema = Schema([Transaction.self, BudgetCategory.self])
        do {
            container = try ModelContainer(for: schema)
        } catch {
            // Falling back to an in-memory store keeps the app launchable
            // rather than crashing on open -- the user can still log
            // purchases for the session and the settings screen surfaces the
            // problem, which beats a TestFlight build that dies at startup.
            let fallback = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try! ModelContainer(for: schema, configurations: fallback)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .tint(.tudgetAccent)
        }
        .modelContainer(container)
    }
}
