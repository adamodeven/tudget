import XCTest
@testable import Tudget

/// Mirrors the budget math in `budget.py`.
final class BudgetCalculatorTests: XCTestCase {

    private let foodID = UUID()
    private let goingOutID = UUID()

    private var limits: [BudgetCalculator.CategoryLimit] {
        [
            .init(id: foodID, name: "Food", emoji: "🍔", monthlyLimit: 400),
            .init(id: goingOutID, name: "Going Out", emoji: "🍻", monthlyLimit: 200),
        ]
    }

    private func record(_ categoryID: UUID?, _ amount: Double, daysAgo: Int = 0)
        -> BudgetCalculator.SpendRecord {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return .init(categoryID: categoryID, amountInHomeCurrency: amount, timestamp: date)
    }

    func testSpendIsAttributedToTheRightCategory() {
        let summary = BudgetCalculator.summary(
            categories: limits,
            records: [record(foodID, 30), record(goingOutID, 45), record(foodID, 20)]
        )

        let food = summary.categories.first { $0.id == foodID }
        XCTAssertEqual(food?.spent, 50)
        XCTAssertEqual(food?.remaining, 350)

        let goingOut = summary.categories.first { $0.id == goingOutID }
        XCTAssertEqual(goingOut?.spent, 45)
    }

    func testTotalsCoverEveryCategory() {
        let summary = BudgetCalculator.summary(
            categories: limits,
            records: [record(foodID, 100), record(goingOutID, 50)]
        )
        XCTAssertEqual(summary.totalSpent, 150)
        XCTAssertEqual(summary.totalLimit, 600)
        XCTAssertEqual(summary.totalRemaining, 450)
        XCTAssertFalse(summary.isOverBudget)
    }

    /// Uncategorized spend is reported, but must not move category or total
    /// budgets -- same rule the Python version follows.
    func testUncategorizedSpendIsSeparate() {
        let summary = BudgetCalculator.summary(
            categories: limits,
            records: [record(foodID, 100), record(nil, 75)]
        )
        XCTAssertEqual(summary.totalSpent, 100)
        XCTAssertEqual(summary.uncategorizedSpent, 75)
        XCTAssertEqual(summary.uncategorizedCount, 1)
    }

    func testOverspendingReportsNegativeRemaining() {
        let summary = BudgetCalculator.summary(
            categories: limits,
            records: [record(foodID, 450)]
        )
        let food = summary.categories.first { $0.id == foodID }
        XCTAssertEqual(food?.remaining, -50)
        XCTAssertEqual(food?.isOverBudget, true)
        // The bar clamps, but the label shouldn't.
        XCTAssertEqual(food?.fractionUsed, 1.0)
        XCTAssertEqual(try XCTUnwrap(food?.rawFractionUsed), 1.125, accuracy: 0.0001)
    }

    func testLastMonthIsExcluded() {
        let lastMonth = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        let summary = BudgetCalculator.summary(
            categories: limits,
            records: [
                record(foodID, 100),
                .init(categoryID: foodID, amountInHomeCurrency: 999, timestamp: lastMonth),
            ]
        )
        XCTAssertEqual(summary.totalSpent, 100)
    }

    func testZeroLimitCategoryNeverFillsItsBar() {
        let id = UUID()
        let summary = BudgetCalculator.summary(
            categories: [.init(id: id, name: "Unbudgeted", emoji: "", monthlyLimit: 0)],
            records: [record(id, 50)]
        )
        let category = summary.categories.first
        XCTAssertEqual(category?.fractionUsed, 0)
        XCTAssertEqual(category?.spent, 50)
    }

    func testConfirmationLineMatchesTheSMSWording() {
        let summary = BudgetCalculator.summary(
            categories: limits,
            records: [record(foodID, 13)]
        )
        let line = BudgetCalculator.confirmationLine(
            for: foodID, summary: summary, homeCurrency: "USD"
        )
        XCTAssertEqual(line, "Food: $387 of $400 left. Month total: $587 of $600 left.")
    }

    func testConfirmationLineWhenOverBudget() {
        let summary = BudgetCalculator.summary(
            categories: limits,
            records: [record(foodID, 450)]
        )
        let line = BudgetCalculator.confirmationLine(
            for: foodID, summary: summary, homeCurrency: "USD"
        )
        XCTAssertTrue(line.hasPrefix("Food: $50 over your $400 budget."), line)
    }

    func testMonthBoundsAreHalfOpen() {
        let bounds = BudgetCalculator.monthBounds(containing: Date())
        XCTAssertTrue(BudgetCalculator.isInMonth(bounds.start, of: Date()))
        XCTAssertFalse(BudgetCalculator.isInMonth(bounds.end, of: Date()))
    }
}

final class BudgetTemplateTests: XCTestCase {

    func testSuggestedLimitsSpendEightyPercentOfTakeHome() {
        let limits = BudgetCategory.suggestedLimits(takeHomePay: 5000)
        let total = limits.values.reduce(0, +)
        // 50% needs + 30% wants, leaving 20% for savings.
        XCTAssertEqual(total, 4000, accuracy: 1.0)
    }

    func testSavingsFractionIsTheRemainder() {
        XCTAssertEqual(BudgetCategory.savingsFraction, 0.20, accuracy: 0.0001)
    }

    func testEveryTemplateGetsALimit() {
        let limits = BudgetCategory.suggestedLimits(takeHomePay: 3000)
        for template in BudgetCategory.templates {
            XCTAssertNotNil(limits[template.name], "missing limit for \(template.name)")
        }
    }
}
