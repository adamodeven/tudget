import Foundation
import SwiftData

/// How a purchase got into the ledger. Informational, but it's what tells you
/// at a glance whether you typed something in or it came off a screenshot.
enum TransactionSource: String, Codable, CaseIterable, Sendable {
    case manual
    case quickEntry
    case screenshot
    case shareExtension
    case imported

    var label: String {
        switch self {
        case .manual: return "Typed"
        case .quickEntry: return "Quick entry"
        case .screenshot: return "Screenshot"
        case .shareExtension: return "Shared"
        case .imported: return "Imported"
        }
    }

    var systemImage: String {
        switch self {
        case .manual: return "keyboard"
        case .quickEntry: return "bolt.fill"
        case .screenshot: return "camera.viewfinder"
        case .shareExtension: return "square.and.arrow.up"
        case .imported: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// One purchase.
///
/// `amount` and `currencyCode` are always the purchase as it actually
/// happened; `amountInHomeCurrency` is that amount converted at log time and
/// is what every budget total sums. Storing both means a €12.47 lunch always
/// displays as €12.47 even though it counts against a USD budget, and later FX
/// moves don't silently rewrite past spending.
///
/// Every property has a default and the relationship is optional: that's what
/// CloudKit requires of a SwiftData model, and retrofitting it later means a
/// migration, so it's done up front whether or not sync is switched on yet.
@Model
final class Transaction {

    /// Stable identity across devices and across the share extension. Not a
    /// `.unique` attribute -- CloudKit forbids those -- so de-duplication is
    /// done by explicit lookup in `Ledger`.
    var uuid: UUID = UUID()

    var merchant: String = ""
    var amount: Double = 0
    var currencyCode: String = "USD"
    var amountInHomeCurrency: Double = 0
    var homeCurrencyCode: String = "USD"

    var category: BudgetCategory?

    var note: String?
    /// Filename inside the shared receipts directory, not a full path -- the
    /// container URL differs between the app and its extensions.
    var receiptFilename: String?

    var timestamp: Date = Date()
    var createdAt: Date = Date()

    /// Backing store for `source`. SwiftData handles a raw string more
    /// predictably than an enum across schema changes.
    var sourceRaw: String = TransactionSource.manual.rawValue

    init(
        uuid: UUID = UUID(),
        merchant: String = "",
        amount: Double = 0,
        currencyCode: String = "USD",
        amountInHomeCurrency: Double = 0,
        homeCurrencyCode: String = "USD",
        category: BudgetCategory? = nil,
        note: String? = nil,
        receiptFilename: String? = nil,
        timestamp: Date = Date(),
        source: TransactionSource = .manual,
        createdAt: Date = Date()
    ) {
        self.uuid = uuid
        self.merchant = merchant
        self.amount = amount
        self.currencyCode = currencyCode
        self.amountInHomeCurrency = amountInHomeCurrency
        self.homeCurrencyCode = homeCurrencyCode
        self.category = category
        self.note = note
        self.receiptFilename = receiptFilename
        self.timestamp = timestamp
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
    }

    var source: TransactionSource {
        get { TransactionSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    var isCategorized: Bool { category != nil }

    /// The purchase in its original currency, e.g. "€12.47".
    var formattedAmount: String {
        Currency.format(amount, code: currencyCode)
    }

    /// The converted amount, or nil when it would just repeat
    /// `formattedAmount` because no conversion happened.
    var formattedHomeAmount: String? {
        guard currencyCode != homeCurrencyCode else { return nil }
        return Currency.format(amountInHomeCurrency, code: homeCurrencyCode)
    }

    var displayMerchant: String {
        merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unknown" : merchant
    }
}
