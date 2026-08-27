import Foundation
import SwiftData

/// A spending category and its monthly limit, in the user's home currency.
@Model
final class BudgetCategory {

    /// Stable identity for syncing with the optional backend; the name is a
    /// display label the user can rename freely.
    @Attribute(.unique) var uuid: UUID
    var name: String
    var monthlyLimit: Double
    var emoji: String
    var sortOrder: Int
    var createdAt: Date

    /// Transactions filed under this category. Deleting a category leaves its
    /// transactions in place, uncategorized, rather than destroying spend
    /// history the user may still want.
    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction] = []

    init(
        uuid: UUID = UUID(),
        name: String,
        monthlyLimit: Double,
        emoji: String = "",
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.uuid = uuid
        self.name = name
        self.monthlyLimit = monthlyLimit
        self.emoji = emoji
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    var displayName: String {
        emoji.isEmpty ? name : "\(emoji) \(name)"
    }
}

extension BudgetCategory {

    /// The starter set, matching `setup_budget.py`'s modified 50/30/20 split:
    /// 50% needs, 30% wants, 20% savings. Savings is tracked separately by the
    /// user and isn't created as a spending category.
    struct Template {
        let name: String
        let emoji: String
        let group: Group
        let fractionOfTakeHome: Double

        enum Group: String {
            case needs = "Needs"
            case wants = "Wants"
        }
    }

    static let templates: [Template] = [
        Template(name: "Food", emoji: "🍔", group: .needs, fractionOfTakeHome: 0.30),
        Template(name: "Transport", emoji: "🚗", group: .needs, fractionOfTakeHome: 0.15),
        Template(name: "Subscriptions", emoji: "🔁", group: .needs, fractionOfTakeHome: 0.05),
        Template(name: "Going Out", emoji: "🍻", group: .wants, fractionOfTakeHome: 0.15),
        Template(name: "Shopping", emoji: "🛍", group: .wants, fractionOfTakeHome: 0.10),
        Template(name: "Other", emoji: "🧾", group: .wants, fractionOfTakeHome: 0.05),
    ]

    /// Share of take-home pay the templates above don't spend -- what's left
    /// for savings, shown during setup for reference.
    static var savingsFraction: Double {
        max(0, 1.0 - templates.reduce(0) { $0 + $1.fractionOfTakeHome })
    }

    static func suggestedLimits(takeHomePay: Double) -> [String: Double] {
        var limits: [String: Double] = [:]
        for template in templates {
            limits[template.name] = (takeHomePay * template.fractionOfTakeHome).rounded()
        }
        return limits
    }
}
