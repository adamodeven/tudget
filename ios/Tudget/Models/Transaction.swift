import Foundation
import SwiftData

/// How a transaction got into the ledger. Purely informational, but it's what
/// tells you at a glance whether you typed something in or it came off a
/// screenshot.
enum TransactionSource: String, Codable, CaseIterable {
    case manual
    case screenshot
    case shareExtension
    case email
    case plaid

    var label: String {
        switch self {
        case .manual: return "Typed"
        case .screenshot: return "Screenshot"
        case .shareExtension: return "Shared"
        case .email: return "Bank email"
        case .plaid: return "Bank sync"
        }
    }

    var systemImage: String {
        switch self {
        case .manual: return "keyboard"
        case .screenshot: return "camera.viewfinder"
        case .shareExtension: return "square.and.arrow.up"
        case .email: return "envelope"
        case .plaid: return "building.columns"
        }
    }
}

/// One purchase.
///
/// `amount` and `currencyCode` are always the purchase as it actually
/// happened; `amountInHomeCurrency` is that amount converted at log time and
/// is what every budget total sums. Storing both means a €12.47 lunch always
/// displays as €12.47 even though it counts against a USD budget, and that
/// later FX moves don't silently rewrite past spending.
@Model
final class Transaction {

    @Attribute(.unique) var uuid: UUID
    var merchant: String
    var amount: Double
    var currencyCode: String
    var amountInHomeCurrency: Double
    var homeCurrencyCode: String
    var card: String
    var category: BudgetCategory?
    var receiptFilename: String?
    var note: String?
    var timestamp: Date
    var createdAt: Date

    /// Backing store for `source`. SwiftData handles the raw string more
    /// predictably across schema changes than an enum property.
    var sourceRaw: String

    /// Set once the transaction has been pushed to the optional backend, so
    /// sync doesn't re-send it.
    var syncedAt: Date?

    init(
        uuid: UUID = UUID(),
        merchant: String,
        amount: Double,
        currencyCode: String,
        amountInHomeCurrency: Double,
        homeCurrencyCode: String,
        card: String = "Manual",
        category: BudgetCategory? = nil,
        receiptFilename: String? = nil,
        note: String? = nil,
        timestamp: Date = Date(),
        source: TransactionSource = .manual,
        createdAt: Date = Date(),
        syncedAt: Date? = nil
    ) {
        self.uuid = uuid
        self.merchant = merchant
        self.amount = amount
        self.currencyCode = currencyCode
        self.amountInHomeCurrency = amountInHomeCurrency
        self.homeCurrencyCode = homeCurrencyCode
        self.card = card
        self.category = category
        self.receiptFilename = receiptFilename
        self.note = note
        self.timestamp = timestamp
        self.sourceRaw = source.rawValue
        self.createdAt = createdAt
        self.syncedAt = syncedAt
    }

    var source: TransactionSource {
        get { TransactionSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    /// The purchase in its original currency, e.g. "€12.47".
    var formattedAmount: String {
        Currency.format(amount, code: currencyCode)
    }

    /// The same purchase in the home currency, e.g. "$13.47". Nil when the
    /// purchase was already in the home currency and the conversion would just
    /// repeat `formattedAmount`.
    var formattedHomeAmount: String? {
        guard currencyCode != homeCurrencyCode else { return nil }
        return Currency.format(amountInHomeCurrency, code: homeCurrencyCode)
    }

    var isCategorized: Bool { category != nil }
}
