import Foundation
import SwiftData

/// A spending category and what it's allowed per budget period, in the user's
/// home currency.
///
/// CloudKit-shaped like `Transaction`: defaults everywhere, optional to-many
/// relationship, no unique attribute.
@Model
final class BudgetCategory {

    var uuid: UUID = UUID()
    var name: String = ""

    /// Limit for one budget *period*, not one month -- with a fortnightly
    /// cycle these are half what the old monthly Notion limits were.
    var periodLimit: Double = 0

    var emoji: String = ""
    /// Raw value of a `CategoryTint`; a plain string keeps the model simple
    /// and CloudKit-friendly.
    var tintRaw: String = CategoryTint.blue.rawValue

    var sortOrder: Int = 0
    var createdAt: Date = Date()

    /// Deleting a category leaves its transactions in place, uncategorized,
    /// rather than destroying spend history you may still want.
    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    var transactions: [Transaction]? = []

    init(
        uuid: UUID = UUID(),
        name: String = "",
        periodLimit: Double = 0,
        emoji: String = "",
        tint: CategoryTint = .blue,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.uuid = uuid
        self.name = name
        self.periodLimit = periodLimit
        self.emoji = emoji
        self.tintRaw = tint.rawValue
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }

    var tint: CategoryTint {
        get { CategoryTint(rawValue: tintRaw) ?? .blue }
        set { tintRaw = newValue.rawValue }
    }

    var displayName: String {
        emoji.isEmpty ? name : "\(emoji) \(name)"
    }
}

// MARK: - Starter templates

extension BudgetCategory {

    /// The starter set, carried over from the old `setup_budget.py`: a
    /// modified 50/30/20 split -- 50% needs, 30% wants, 20% savings. Savings
    /// isn't a spending category, so it's shown during setup for reference
    /// and never created.
    struct Template: Identifiable {
        let name: String
        let emoji: String
        let tint: CategoryTint
        let group: Group
        let fractionOfTakeHome: Double

        var id: String { name }

        enum Group: String {
            case needs = "Needs"
            case wants = "Wants"
        }
    }

    static let templates: [Template] = [
        Template(name: "Food", emoji: "🍔", tint: .amber, group: .needs, fractionOfTakeHome: 0.30),
        Template(name: "Transport", emoji: "🚗", tint: .blue, group: .needs, fractionOfTakeHome: 0.15),
        Template(name: "Subscriptions", emoji: "🔁", tint: .sky, group: .needs, fractionOfTakeHome: 0.05),
        Template(name: "Going Out", emoji: "🍻", tint: .mauve, group: .wants, fractionOfTakeHome: 0.15),
        Template(name: "Shopping", emoji: "🛍", tint: .green, group: .wants, fractionOfTakeHome: 0.10),
        // "Other" is the neutral bucket by design -- see CategoryTint.
        Template(name: "Other", emoji: "🧾", tint: .neutral, group: .wants, fractionOfTakeHome: 0.05),
    ]

    /// Share of take-home the templates don't spend -- what's left for
    /// savings, shown during setup for reference.
    static var savingsFraction: Double {
        max(0, 1.0 - templates.reduce(0) { $0 + $1.fractionOfTakeHome })
    }

    /// Suggested per-period limits from take-home pay *for that same period*.
    static func suggestedLimits(takeHomePerPeriod: Double) -> [String: Double] {
        var limits: [String: Double] = [:]
        for template in templates {
            limits[template.name] = (takeHomePerPeriod * template.fractionOfTakeHome).rounded()
        }
        return limits
    }

    /// Builds the starter categories, in template order.
    static func makeStarterSet(takeHomePerPeriod: Double) -> [BudgetCategory] {
        let limits = suggestedLimits(takeHomePerPeriod: takeHomePerPeriod)
        return templates.enumerated().map { index, template in
            BudgetCategory(
                name: template.name,
                periodLimit: limits[template.name] ?? 0,
                emoji: template.emoji,
                tint: template.tint,
                sortOrder: index
            )
        }
    }
}
