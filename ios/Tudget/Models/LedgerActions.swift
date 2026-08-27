import Foundation
import SwiftData

/// Everything that writes to the ledger.
///
/// Kept in one place because every write has the same two obligations beyond
/// inserting a row: convert the amount into the home currency (so budget math
/// has something to sum), and keep the App Group's category snapshot in step
/// so the share extension's picker doesn't drift.
@MainActor
enum LedgerActions {

    // MARK: - Transactions

    @discardableResult
    static func addTransaction(
        in context: ModelContext,
        merchant: String,
        amount: Double,
        currencyCode: String,
        category: BudgetCategory?,
        receiptData: Data? = nil,
        note: String? = nil,
        source: TransactionSource = .manual,
        timestamp: Date = Date(),
        settings: AppSettings
    ) async -> Transaction {
        let home = settings.homeCurrency
        let converted = await FXRateService.shared.convert(
            amount, from: currencyCode, to: home
        )

        var receiptFilename: String?
        if let receiptData {
            receiptFilename = try? SharedStore.saveReceipt(receiptData)
        }

        let transaction = Transaction(
            merchant: merchant,
            amount: amount,
            currencyCode: currencyCode,
            amountInHomeCurrency: converted,
            homeCurrencyCode: home,
            card: source == .plaid || source == .email ? "Bank" : "Manual",
            category: category,
            receiptFilename: receiptFilename,
            note: note,
            timestamp: timestamp,
            source: source
        )

        context.insert(transaction)
        try? context.save()
        return transaction
    }

    /// Re-runs the home-currency conversion for an edited transaction, since
    /// changing the amount or currency invalidates the stored conversion.
    static func updateAmount(
        _ transaction: Transaction,
        amount: Double,
        currencyCode: String,
        in context: ModelContext,
        settings: AppSettings
    ) async {
        let home = settings.homeCurrency
        transaction.amount = amount
        transaction.currencyCode = currencyCode
        transaction.homeCurrencyCode = home
        transaction.amountInHomeCurrency = await FXRateService.shared.convert(
            amount, from: currencyCode, to: home
        )
        transaction.syncedAt = nil
        try? context.save()
    }

    static func delete(_ transaction: Transaction, in context: ModelContext) {
        if let filename = transaction.receiptFilename {
            SharedStore.deleteReceipt(filename)
        }
        context.delete(transaction)
        try? context.save()
    }

    /// Recomputes every transaction's home-currency amount. Run when the user
    /// changes their home currency, otherwise old rows would keep counting
    /// against the budget at their old conversion.
    static func recalculateHomeAmounts(
        in context: ModelContext, settings: AppSettings
    ) async {
        let home = settings.homeCurrency
        let descriptor = FetchDescriptor<Transaction>()
        guard let transactions = try? context.fetch(descriptor) else { return }

        for transaction in transactions where transaction.homeCurrencyCode != home {
            transaction.amountInHomeCurrency = await FXRateService.shared.convert(
                transaction.amount, from: transaction.currencyCode, to: home
            )
            transaction.homeCurrencyCode = home
            transaction.syncedAt = nil
        }
        try? context.save()
    }

    // MARK: - Categories

    static func createDefaultCategories(
        in context: ModelContext, takeHomePay: Double
    ) {
        let limits = BudgetCategory.suggestedLimits(takeHomePay: takeHomePay)
        for (index, template) in BudgetCategory.templates.enumerated() {
            let category = BudgetCategory(
                name: template.name,
                monthlyLimit: limits[template.name] ?? 0,
                emoji: template.emoji,
                sortOrder: index
            )
            context.insert(category)
        }
        try? context.save()
        publishCategorySnapshot(from: context)
    }

    static func deleteCategory(_ category: BudgetCategory, in context: ModelContext) {
        // The relationship's nullify rule leaves the transactions in place,
        // uncategorized, so history survives deleting a category.
        context.delete(category)
        try? context.save()
        publishCategorySnapshot(from: context)
    }

    /// Mirrors the current categories into the App Group so the share
    /// extension can show a picker.
    static func publishCategorySnapshot(from context: ModelContext) {
        let descriptor = FetchDescriptor<BudgetCategory>(
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)]
        )
        guard let categories = try? context.fetch(descriptor) else { return }
        SharedStore.writeCategorySnapshot(
            categories.map {
                CategorySnapshot(id: $0.uuid, name: $0.name, emoji: $0.emoji)
            }
        )
    }

    // MARK: - Share extension inbox

    /// Drains purchases captured by the share extension into the ledger.
    /// Returns how many were ingested so the UI can acknowledge them.
    @discardableResult
    static func ingestPendingPurchases(
        in context: ModelContext, settings: AppSettings
    ) async -> Int {
        let pending = SharedStore.drainInbox()
        guard !pending.isEmpty else { return 0 }

        let categories = (try? context.fetch(FetchDescriptor<BudgetCategory>())) ?? []
        var ingested = 0

        for purchase in pending {
            // Skip anything already ingested: the inbox file is only removed
            // after a successful save, so a crash mid-ingest could otherwise
            // duplicate a purchase on the next launch.
            let purchaseID = purchase.id
            let existing = try? context.fetch(
                FetchDescriptor<Transaction>(predicate: #Predicate { $0.uuid == purchaseID })
            )
            if let existing, !existing.isEmpty {
                SharedStore.removeFromInbox(purchase.id)
                continue
            }

            let category = purchase.categoryID.flatMap { categoryID in
                categories.first { $0.uuid == categoryID }
            }
            let converted = await FXRateService.shared.convert(
                purchase.amount, from: purchase.currencyCode, to: settings.homeCurrency
            )

            let transaction = Transaction(
                uuid: purchase.id,
                merchant: purchase.merchant,
                amount: purchase.amount,
                currencyCode: purchase.currencyCode,
                amountInHomeCurrency: converted,
                homeCurrencyCode: settings.homeCurrency,
                card: "Manual",
                category: category,
                receiptFilename: purchase.receiptFilename,
                note: purchase.note,
                timestamp: purchase.capturedAt,
                source: .shareExtension
            )
            context.insert(transaction)
            try? context.save()

            SharedStore.removeFromInbox(purchase.id)
            ingested += 1
        }

        return ingested
    }
}
