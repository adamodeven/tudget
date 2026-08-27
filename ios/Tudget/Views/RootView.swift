import SwiftUI
import SwiftData

struct RootView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @Query private var categories: [BudgetCategory]

    @State private var showingAddPurchase = false
    @State private var ingestedBanner: String?

    var body: some View {
        TabView {
            DashboardView(showingAddPurchase: $showingAddPurchase)
                .tabItem { Label("Budget", systemImage: "chart.pie.fill") }

            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .sheet(isPresented: $showingAddPurchase) {
            AddPurchaseView()
        }
        .fullScreenCover(isPresented: Binding(
            get: { !settings.hasCompletedSetup },
            set: { if !$0 { settings.hasCompletedSetup = true } }
        )) {
            BudgetSetupView()
        }
        .overlay(alignment: .top) {
            if let ingestedBanner {
                IngestBanner(message: ingestedBanner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            // Publish on launch so a fresh install's share extension has a
            // category list before the app is ever foregrounded again.
            LedgerActions.publishCategorySnapshot(from: context)
            await ingestPending()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await ingestPending() }
        }
        .onChange(of: categories.map(\.uuid)) { _, _ in
            LedgerActions.publishCategorySnapshot(from: context)
        }
    }

    /// Pulls in anything the share extension captured while the app was
    /// backgrounded, and says so briefly rather than silently changing totals.
    private func ingestPending() async {
        let count = await LedgerActions.ingestPendingPurchases(
            in: context, settings: settings
        )
        guard count > 0 else { return }

        let noun = count == 1 ? "purchase" : "purchases"
        withAnimation { ingestedBanner = "Added \(count) shared \(noun)" }

        try? await Task.sleep(for: .seconds(2.5))
        withAnimation { ingestedBanner = nil }
    }
}

private struct IngestBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.tudgetAccent.opacity(0.4)))
            .padding(.top, 8)
            .shadow(radius: 8, y: 4)
    }
}
