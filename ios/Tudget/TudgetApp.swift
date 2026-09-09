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
                #if DEBUG
                .task {
                    if DebugSeed.isRequested {
                        DebugSeed.run(
                            context: ModelContext(LedgerStore.shared), settings: settings
                        )
                    }
                    // Launch straight onto a given tab, so iterating on one
                    // screen doesn't mean tapping through to it every time:
                    //   SIMCTL_CHILD_TUDGET_TAB=pace
                    if let tab = DebugSeed.requestedTab { router.tab = tab }
                    // ... or straight onto the entry sheet:
                    //   SIMCTL_CHILD_TUDGET_ENTRY="heard:$12 at Blue Bottle"
                    router.entry = DebugSeed.requestedEntry(
                        categoryNames: Ledger.categoryNames(
                            in: ModelContext(LedgerStore.shared)
                        ),
                        defaultCurrency: settings.homeCurrencyCode
                    )
                }
                #endif
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

    /// The entry sheet, and what it should open showing: a spoken purchase
    /// waiting to be confirmed, or empty fields.
    var entry: PurchaseEntryRequest?
    var showingScreenshotImport = false

    /// The purchase currently being given a category, if any.
    var categorizing: Transaction?

    func handle(_ action: QuickAction) {
        switch action {
        case .quickAdd:
            // Nothing outside the app can hold the capture bar down, so a
            // widget or a Shortcut lands on the fields.
            showingScreenshotImport = false
            entry = .manual
        case .screenshot:
            entry = nil
            showingScreenshotImport = true
        case .pace:
            entry = nil
            showingScreenshotImport = false
            tab = .pace
        }
    }

    /// Picks up anything Control Center or a widget left for us.
    func consumePendingAction() {
        guard let action = QuickAction.consume() else { return }
        handle(action)
    }
}
