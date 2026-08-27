import SwiftUI
import SwiftData

struct RootView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var settings = settings

        Group {
            if settings.hasCompletedSetup {
                tabs
            } else {
                BudgetSetupView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Control Center and the widgets leave a note rather than
            // presenting anything themselves; this is where it's picked up.
            if phase == .active { router.consumePendingAction() }
        }
        .onOpenURL { url in
            if let action = QuickAction(url: url) { router.handle(action) }
        }
    }

    private var tabs: some View {
        @Bindable var router = router

        return TabView(selection: $router.tab) {
            Tab("Budget", systemImage: "chart.pie.fill", value: AppRouter.Tab.budget) {
                DashboardView()
            }
            Tab("Pace", systemImage: "chart.xyaxis.line", value: AppRouter.Tab.pace) {
                PaceView()
            }
            Tab("History", systemImage: "list.bullet", value: AppRouter.Tab.history) {
                HistoryView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppRouter.Tab.settings) {
                SettingsView()
            }
        }
        // The single most important affordance in the app: a capture bar that
        // never scrolls away, on every tab, one tap from a logged purchase.
        .tabViewBottomAccessory {
            QuickAddAccessory()
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $router.showingQuickAdd) {
            AddPurchaseView()
        }
        .sheet(isPresented: $router.showingScreenshotImport) {
            ScreenshotImportView()
        }
        .sheet(item: $router.categorizing) { transaction in
            CategorizeSheet(transaction: transaction)
        }
    }
}

/// The persistent capture bar docked above the tab bar.
///
/// It sits in the tab bar's own glass, so it costs no screen real estate and
/// is always within thumb reach -- the whole point being that logging a
/// purchase never requires navigating anywhere first.
private struct QuickAddAccessory: View {

    @Environment(AppRouter.self) private var router

    var body: some View {
        HStack(spacing: 10) {
            Button {
                router.showingQuickAdd = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                    Text("Add a purchase")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Button {
                router.showingScreenshotImport = true
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add from a screenshot")
        }
        .padding(.horizontal, 16)
    }
}

// Lets `sheet(item:)` drive off the transaction being categorized.
extension Transaction: Identifiable {
    var id: UUID { uuid }
}
