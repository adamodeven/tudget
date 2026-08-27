#if DEBUG
import Foundation
import SwiftData

/// Fills the ledger with a plausible half-finished fortnight.
///
/// Debug builds only, and only when asked for explicitly:
///
///     SIMCTL_CHILD_TUDGET_SEED=1 xcrun simctl launch <device> com.adamodeven.tudget
///
/// It exists because the screens worth looking at -- the dashboard, and the
/// pace chart in particular -- say nothing at all until there's a spread of
/// spending behind them. Wiping and reseeding by hand every time is how you
/// end up never checking them.
enum DebugSeed {

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["TUDGET_SEED"] == "1"
    }

    /// Tab to open on launch, from `TUDGET_TAB`.
    static var requestedTab: AppRouter.Tab? {
        switch ProcessInfo.processInfo.environment["TUDGET_TAB"] {
        case "budget": return .budget
        case "pace": return .pace
        case "history": return .history
        case "settings": return .settings
        default: return nil
        }
    }

    @MainActor
    static func run(context: ModelContext, settings: AppSettings) {
        let calendar = Calendar.current

        // Start the cycle a week ago, so there's history behind today and
        // room ahead of it for the projection to say something.
        let anchor = BudgetPeriodCalculator.mondayOnOrBefore(
            calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        )

        settings.homeCurrencyCode = "USD"
        settings.periodLength = .biweekly
        settings.periodAnchor = anchor
        settings.takeHomePerPeriod = 800
        settings.alertsEnabled = true
        settings.hasCompletedSetup = true

        // Clear anything already there, so reseeding is idempotent.
        for transaction in Ledger.allTransactions(in: context) { context.delete(transaction) }
        for category in Ledger.categories(in: context) { context.delete(category) }

        let categories = BudgetCategory.makeStarterSet(takeHomePerPeriod: 800)
        categories.forEach { context.insert($0) }

        func category(_ name: String) -> BudgetCategory? {
            categories.first { $0.name == name }
        }

        // Deliberately a little over pace, so the projection has something
        // worth saying and the warning styling is visible. Spread across the
        // whole elapsed stretch rather than bunched at the start, so the
        // cumulative line climbs steadily the way real spending does.
        let purchases: [(String, Double, String, String, Int)] = [
            ("Trader Joe's", 62.40, "USD", "Food", 0),
            ("Shell", 48.10, "USD", "Transport", 0),
            ("Netflix", 15.99, "USD", "Subscriptions", 1),
            ("Chipotle", 14.35, "USD", "Food", 2),
            ("The Anchor", 43.00, "USD", "Going Out", 3),
            ("Cafe Luna", 12.47, "EUR", "Food", 3),
            ("Uniqlo", 78.00, "USD", "Shopping", 4),
            ("Lyft", 22.60, "USD", "Transport", 5),
            ("Sweetgreen", 16.80, "USD", "Food", 5),
            ("Whole Foods", 91.20, "USD", "Food", 6),
            ("Spotify", 11.99, "USD", "Subscriptions", 7),
            ("Pharmacy", 23.15, "USD", "Other", 8),
            ("The Anchor", 56.50, "USD", "Going Out", 9),
            ("Shell", 51.30, "USD", "Transport", 10),
            ("Amazon", 34.99, "USD", "Shopping", 11),
        ]

        for (merchant, amount, currency, categoryName, dayOffset) in purchases {
            guard let timestamp = calendar.date(byAdding: .day, value: dayOffset, to: anchor),
                  timestamp <= Date() else { continue }

            // Roughly right is fine for seed data; the app converts properly.
            let rate = currency == "EUR" ? 1.08 : 1.0

            context.insert(
                Transaction(
                    merchant: merchant,
                    amount: amount,
                    currencyCode: currency,
                    amountInHomeCurrency: amount * rate,
                    homeCurrencyCode: "USD",
                    category: category(categoryName),
                    timestamp: timestamp,
                    source: .quickEntry
                )
            )
        }

        // Two left uncategorized, so the "Needs a category" path is visible.
        for (merchant, amount, dayOffset) in [("Corner Store", 8.75, 9), ("SQ *COFFEE", 5.40, 11)] {
            guard let timestamp = calendar.date(byAdding: .day, value: dayOffset, to: anchor),
                  timestamp <= Date() else { continue }
            context.insert(
                Transaction(
                    merchant: merchant,
                    amount: amount,
                    currencyCode: "USD",
                    amountInHomeCurrency: amount,
                    homeCurrencyCode: "USD",
                    category: nil,
                    timestamp: timestamp,
                    source: .shareExtension
                )
            )
        }

        Ledger.save(context)
    }
}
#endif
