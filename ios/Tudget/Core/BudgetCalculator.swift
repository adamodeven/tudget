import Foundation

/// Budget math: what's been spent per category this month, what's left, and
/// the month-wide totals. Port of `budget.py`.
///
/// Deliberately operates on plain value types rather than SwiftData models so
/// the arithmetic can be unit-tested without standing up a model container.
/// The view layer maps models into these before calling in.
enum BudgetCalculator {

    struct CategoryLimit: Identifiable, Equatable {
        let id: UUID
        let name: String
        let emoji: String
        let monthlyLimit: Double
    }

    struct SpendRecord: Equatable {
        let categoryID: UUID?
        let amountInHomeCurrency: Double
        let timestamp: Date
    }

    struct CategoryBudget: Identifiable, Equatable {
        let id: UUID
        let name: String
        let emoji: String
        let limit: Double
        let spent: Double

        var remaining: Double { limit - spent }
        var isOverBudget: Bool { remaining < 0 }

        /// 0...1 for the progress bar. An unlimited (zero-limit) category
        /// never fills; an overspent one clamps at full.
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
    }

    struct MonthSummary: Equatable {
        let categories: [CategoryBudget]
        let totalSpent: Double
        let totalLimit: Double
        /// Spend that isn't counted against any category, because the
        /// transaction hasn't been categorized yet.
        let uncategorizedSpent: Double
        let uncategorizedCount: Int

        var totalRemaining: Double { totalLimit - totalSpent }
        var isOverBudget: Bool { totalRemaining < 0 }

        var fractionUsed: Double {
            guard totalLimit > 0 else { return 0 }
            return min(totalSpent / totalLimit, 1.0)
        }
    }

    /// Inclusive start / exclusive end of the calendar month containing `date`.
    static func monthBounds(
        containing date: Date, calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let components = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: components) ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? date
        return (start, end)
    }

    static func isInMonth(
        _ date: Date, of reference: Date, calendar: Calendar = .current
    ) -> Bool {
        let bounds = monthBounds(containing: reference, calendar: calendar)
        return date >= bounds.start && date < bounds.end
    }

    /// Builds the dashboard summary for the month containing `month`.
    ///
    /// Only categorized spend counts toward category and total budgets --
    /// matching the Python behaviour, where an uncategorized transaction is
    /// logged but doesn't move the budget until you say what it was.
    /// Uncategorized spend is surfaced separately so it isn't invisible.
    static func summary(
        categories: [CategoryLimit],
        records: [SpendRecord],
        month: Date = Date(),
        calendar: Calendar = .current
    ) -> MonthSummary {
        let inMonth = records.filter { isInMonth($0.timestamp, of: month, calendar: calendar) }

        var spentByCategory: [UUID: Double] = [:]
        var uncategorizedSpent = 0.0
        var uncategorizedCount = 0

        for record in inMonth {
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
                limit: category.monthlyLimit,
                spent: spentByCategory[category.id] ?? 0
            )
        }

        return MonthSummary(
            categories: categoryBudgets,
            totalSpent: categoryBudgets.reduce(0) { $0 + $1.spent },
            totalLimit: categories.reduce(0) { $0 + $1.monthlyLimit },
            uncategorizedSpent: uncategorizedSpent,
            uncategorizedCount: uncategorizedCount
        )
    }

    /// The line the app shows after categorizing a purchase, mirroring the
    /// text the Python server texts back:
    /// "Food: $387 of $400 left. Month total: $587 of $600 left."
    static func confirmationLine(
        for categoryID: UUID,
        summary: MonthSummary,
        homeCurrency: String
    ) -> String {
        guard let category = summary.categories.first(where: { $0.id == categoryID }) else {
            return totalLine(summary: summary, homeCurrency: homeCurrency)
        }
        let categoryPart = amountLine(
            label: category.name,
            remaining: category.remaining,
            limit: category.limit,
            homeCurrency: homeCurrency
        )
        return "\(categoryPart) \(totalLine(summary: summary, homeCurrency: homeCurrency))"
    }

    private static func totalLine(summary: MonthSummary, homeCurrency: String) -> String {
        amountLine(
            label: "Month total",
            remaining: summary.totalRemaining,
            limit: summary.totalLimit,
            homeCurrency: homeCurrency
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
