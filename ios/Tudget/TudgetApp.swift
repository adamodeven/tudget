import SwiftUI
import SwiftData

@main
struct TudgetApp: App {

    /// One settings object for the whole app, reading through to the shared
    /// App Group so the extensions can't disagree with it.
    @State private var settings = AppSettings.shared
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(router)
                .tint(.accentColor)
        }
        .modelContainer(LedgerStore.shared)
    }
}

/// Where the app should be, and what it should be showing over the top.
///
/// Kept separate from the views so Control Center, the widgets, and the share
/// extension all have one thing to steer.
@Observable
final class AppRouter {

    enum Tab: Hashable {
        case budget
        case pace
        case history
        case settings
    }

    var tab: Tab = .budget

    var showingQuickAdd = false
    var showingScreenshotImport = false

    /// The purchase currently being given a category, if any.
    var categorizing: Transaction?

    func handle(_ action: QuickAction) {
        switch action {
        case .quickAdd:
            showingScreenshotImport = false
            showingQuickAdd = true
        case .screenshot:
            showingQuickAdd = false
            showingScreenshotImport = true
        }
    }

    /// Picks up anything Control Center or a widget left for us.
    func consumePendingAction() {
        guard let action = QuickAction.consume() else { return }
        handle(action)
    }
}
