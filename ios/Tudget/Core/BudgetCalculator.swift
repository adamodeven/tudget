import Foundation

/// Budget maths: what's been spent per category this period, what's left, and
/// the period-wide totals.
///
/// Deliberately operates on plain value types rather than SwiftData models, so
/// the arithmetic unit-tests without standing up a model container and the
/// widgets can run it over a cheap snapshot. The view layer maps models into
/// these before calling in.
enum BudgetCalculator {

    struct CategoryLimit: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let emoji: String
        let tint: CategoryTint
        let periodLimit: Double
    }

    struct SpendRecord: Equatable, Sendable {
        let categoryID: UUID?
        let amountInHomeCurrency: Double
        let timestamp: Date
    }

    struct CategoryBudget: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let emoji: String
        let tint: CategoryTint
        let limit: Double
        let spent: Double

        var remaining: Double { limit - spent }
        var isOverBudget: Bool { remaining < 0 }

        /// 0...1 for a progress ring. A zero-limit category never fills; an
        /// overspent one clamps at full.
        var fractionUsed: Double {
            guard limit > 0 else { return 0 }
            return min(spent / limit, 1.0)
        }

        /// Uncapped, for the "142% of budget" label.
        var rawFractionUsed: Double {
            guard limit > 0 else { return 0 }
            return spent / limit
        }

        var displayName: String {
            emoji.isEmpty ? name : "\(emoji) \(name)"
        }

        /// Where this category sits, used to pick colour and copy.
        func health(fractionElapsed: Double) -> BudgetHealth {
            if isOverBudget { return .over }
            guard limit > 0 else { return .healthy }
            // "Behind" only means anything once there's some period elapsed to
            // be behind against.
            if rawFractionUsed >= 0.9 { return .critical }
            if fractionElapsed > 0.05, rawFractionUsed > fractionElapsed + 0.15 { return .ahead }
            return .healthy
        }
    }

    struct PeriodSummary: Equatable, Sendable {
        let period: BudgetPeriod
        let categories: [CategoryBudget]
        let totalSpent: Double
        let totalLimit: Double
        /// Spend not counted against any category because the purchase hasn't
        /// been categorized yet.
        let uncategorizedSpent: Double
        let uncategorizedCount: Int
        let homeCurrency: String

        var totalRemaining: Double { totalLimit - totalSpent }
        var isOverBudget: Bool { totalRemaining < 0 }

        var fractionUsed: Double {
            guard totalLimit > 0 else { return 0 }
            return min(totalSpent / totalLimit, 1.0)
        }

        var rawFractionUsed: Double {
            guard totalLimit > 0 else { return 0 }
            return totalSpent / totalLimit
        }

        /// What you can spend per remaining day and still land on budget.
        func dailyAllowance(asOf now: Date = Date(), calendar: Calendar = .current) -> Double {
            let remainingDays = period.remainingDays(asOf: now, calendar: calendar)
            guard remainingDays > 0 else { return max(0, totalRemaining) }
            return totalRemaining / Double(remainingDays)
        }
    }

    enum BudgetHealth: Sendable {
        /// On or under pace.
        case healthy
        /// Spending faster than the period is elapsing.
        case ahead
        /// Nearly out.
        case critical
        /// Past the limit.
        case over
    }

    /// Builds the dashboard summary for one period.
    ///
    /// Only categorized spend counts toward category and total budgets --
    /// carried over from the server behaviour, where a purchase is logged
    /// immediately but doesn't move the budget until you say what it was.
    /// Uncategorized spend is surfaced separately so it's never invisible.
    static func summary(
        categories: [CategoryLimit],
        records: [SpendRecord],
        period: BudgetPeriod,
        homeCurrency: String,
        calendar: Calendar = .current
    ) -> PeriodSummary {
        let inPeriod = records.filter { period.contains($0.timestamp, calendar: calendar) }

        var spentByCategory: [UUID: Double] = [:]
        var uncategorizedSpent = 0.0
        var uncategorizedCount = 0

        for record in inPeriod {
            if let categoryID = record.categoryID {
                spentByCategory[categoryID, default: 0] += record.amountInHomeCurrency
            } else {
                uncategorizedSpent += record.amountInHomeCurrency
                uncategorizedCount += 1
            }
        }

        let categoryBudgets = categories.map { category in
            CategoryBudget(
                id: category.id,
                name: category.name,
                emoji: category.emoji,
                tint: category.tint,
                limit: category.periodLimit,
                spent: spentByCategory[category.id] ?? 0
            )
        }

        return PeriodSummary(
            period: period,
            categories: categoryBudgets,
            totalSpent: categoryBudgets.reduce(0) { $0 + $1.spent },
            totalLimit: categories.reduce(0) { $0 + $1.periodLimit },
            uncategorizedSpent: uncategorizedSpent,
            uncategorizedCount: uncategorizedCount,
            homeCurrency: homeCurrency
        )
    }

    /// The line shown after categorizing a purchase, carried over verbatim
    /// from what the server used to text back:
    /// "Food: $387 of $400 left. Period total: $587 of $600 left."
    static func confirmationLine(
        for categoryID: UUID,
        summary: PeriodSummary
    ) -> String {
        guard let category = summary.categories.first(where: { $0.id == categoryID }) else {
            return totalLine(summary: summary)
        }
        let categoryPart = amountLine(
            label: category.name,
            remaining: category.remaining,
            limit: category.limit,
            homeCurrency: summary.homeCurrency
        )
        return "\(categoryPart) \(totalLine(summary: summary))"
    }

    private static func totalLine(summary: PeriodSummary) -> String {
        amountLine(
            label: "Period total",
            remaining: summary.totalRemaining,
            limit: summary.totalLimit,
            homeCurrency: summary.homeCurrency
        )
    }

    private static func amountLine(
        label: String, remaining: Double, limit: Double, homeCurrency: String
    ) -> String {
        let limitText = Currency.formatCompact(limit, code: homeCurrency)
        if remaining >= 0 {
            let remainingText = Currency.formatCompact(remaining, code: homeCurrency)
            return "\(label): \(remainingText) of \(limitText) left."
        }
        let overText = Currency.formatCompact(abs(remaining), code: homeCurrency)
        return "\(label): \(overText) over your \(limitText) budget."
    }
}
