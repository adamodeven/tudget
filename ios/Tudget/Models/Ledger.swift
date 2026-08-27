import Foundation
import SwiftData
import WidgetKit

/// Every read and write against the ledger, in one place.
///
/// Views, the share extension, the App Intents, and the widgets all go through
/// here, so behaviour can't drift between "logged in the app" and "shared from
/// the share sheet" -- and so there's exactly one place that remembers to
/// refresh the widget timelines after a change.
enum Ledger {

    // MARK: - Reading

    static func categories(in context: ModelContext) -> [BudgetCategory] {
        let descriptor = FetchDescriptor<BudgetCategory>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func categoryNames(in context: ModelContext) -> [String] {
        categories(in: context).map(\.name)
    }

    static func category(withID uuid: UUID, in context: ModelContext) -> BudgetCategory? {
        let descriptor = FetchDescriptor<BudgetCategory>(
            predicate: #Predicate { $0.uuid == uuid }
        )
        return try? context.fetch(descriptor).first
    }

    /// All transactions, newest first.
    static func allTransactions(in context: ModelContext) -> [Transaction] {
        let descriptor = FetchDescriptor<Transaction>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func transactions(
        in period: BudgetPeriod, context: ModelContext, calendar: Calendar = .current
    ) -> [Transaction] {
        let start = period.start
        let end = period.end
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Purchases still waiting to be told what they were.
    static func uncategorized(in context: ModelContext) -> [Transaction] {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.category == nil },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Mapping into the calculator's value types

    static func limits(from categories: [BudgetCategory]) -> [BudgetCalculator.CategoryLimit] {
        categories.map {
            BudgetCalculator.CategoryLimit(
                id: $0.uuid,
                name: $0.name,
                emoji: $0.emoji,
                tint: $0.tint,
                periodLimit: $0.periodLimit
            )
        }
    }

    static func spendRecords(from transactions: [Transaction]) -> [BudgetCalculator.SpendRecord] {
        transactions.map {
            BudgetCalculator.SpendRecord(
                categoryID: $0.category?.uuid,
                amountInHomeCurrency: $0.amountInHomeCurrency,
                timestamp: $0.timestamp
            )
        }
    }

    /// The whole dashboard picture for one period.
    static func summary(
        for period: BudgetPeriod,
        context: ModelContext,
        settings: AppSettings
    ) -> BudgetCalculator.PeriodSummary {
        let categories = categories(in: context)
        let transactions = transactions(in: period, context: context)
        return BudgetCalculator.summary(
            categories: limits(from: categories),
            records: spendRecords(from: transactions),
            period: period,
            homeCurrency: settings.homeCurrencyCode
        )
    }

    static func projection(
        for period: BudgetPeriod,
        context: ModelContext,
        settings: AppSettings,
        now: Date = Date()
    ) -> RunwayProjection {
        let categories = categories(in: context)
        let transactions = transactions(in: period, context: context)
        return RunwayProjection.make(
            period: period,
            limit: categories.reduce(0) { $0 + $1.periodLimit },
            records: spendRecords(from: transactions),
            homeCurrency: settings.homeCurrencyCode,
            now: now
        )
    }

    // MARK: - Writing

    /// Records a purchase, converting it into the home currency at log time.
    ///
    /// Conversion happens once, here, and the result is stored -- so a later
    /// FX move never rewrites what a past purchase cost against the budget.
    @discardableResult
    static func record(
        merchant: String,
        amount: Double,
        currencyCode: String,
        category: BudgetCategory?,
        note: String? = nil,
        receiptFilename: String? = nil,
        timestamp: Date = Date(),
        source: TransactionSource,
        context: ModelContext,
        settings: AppSettings
    ) async -> Transaction {
        let home = settings.homeCurrencyCode
        let converted = await FXRateService.shared.convert(amount, from: currencyCode, to: home)

        let transaction = Transaction(
            merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: amount,
            currencyCode: currencyCode,
            amountInHomeCurrency: converted,
            homeCurrencyCode: home,
            category: category,
            note: note,
            receiptFilename: receiptFilename,
            timestamp: timestamp,
            source: source
        )

        context.insert(transaction)
        save(context)
        return transaction
    }

    static func categorize(
        _ transaction: Transaction,
        as category: BudgetCategory?,
        context: ModelContext
    ) {
        transaction.category = category
        save(context)
    }

    static func delete(_ transaction: Transaction, context: ModelContext) {
        if let filename = transaction.receiptFilename {
            AppGroup.deleteReceipt(filename)
        }
        context.delete(transaction)
        save(context)
    }

    static func delete(_ category: BudgetCategory, context: ModelContext) {
        // The relationship's `.nullify` rule leaves the purchases in place,
        // uncategorized, rather than destroying spend history.
        context.delete(category)
        save(context)
    }

    /// Replaces the whole category set -- used when setup runs again.
    static func replaceCategories(
        with categories: [BudgetCategory], context: ModelContext
    ) {
        for existing in self.categories(in: context) {
            context.delete(existing)
        }
        for category in categories {
            context.insert(category)
        }
        save(context)
    }

    /// Saves, then tells WidgetKit something changed.
    ///
    /// Every mutation above funnels through here so no caller has to remember
    /// the widget refresh -- a stale Home Screen number is exactly the kind of
    /// thing that makes a budget app feel untrustworthy.
    static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            // A failed save is worth knowing about in the console, but there's
            // nothing useful to show the user mid-entry.
            print("Tudget: save failed — \(error)")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
