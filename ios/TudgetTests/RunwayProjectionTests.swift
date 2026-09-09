import XCTest
@testable import Tudget

/// The pace projection -- the number the app leads with, so it needs to be
/// right at the edges as well as in the middle.
final class RunwayProjectionTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)!
    }

    private var anchor: Date { date("2026-08-24") }

    private var period: BudgetPeriod {
        BudgetPeriodCalculator.period(
            containing: anchor, anchor: anchor, length: .biweekly, calendar: calendar
        )
    }

    private func spend(_ amount: Double, on day: String) -> BudgetCalculator.SpendRecord {
        BudgetCalculator.SpendRecord(
            categoryID: UUID(), amountInHomeCurrency: amount, timestamp: date(day)
        )
    }

    private func make(
        records: [BudgetCalculator.SpendRecord], limit: Double, now: String
    ) -> RunwayProjection {
        RunwayProjection.make(
            period: period, limit: limit, records: records,
            homeCurrency: "USD", now: date(now), calendar: calendar
        )
    }

    func testEvenSpendingIsOnTrack() {
        // $40/day against $560 over 14 days is exactly on pace.
        let records = (0..<7).map { spend(40, on: "2026-08-\(24 + $0)") }
        let projection = make(records: records, limit: 560, now: "2026-08-30")

        XCTAssertEqual(projection.spent, 280, accuracy: 0.001)
        XCTAssertEqual(projection.dailyBurn, 40, accuracy: 0.001)
        XCTAssertEqual(projection.projectedTotal, 560, accuracy: 0.001)
        XCTAssertEqual(projection.pace, .onTrack)
        XCTAssertNil(projection.runOutDate, "spending exactly to the limit isn't running out early")
    }

    func testOverspendingProjectsARunOutDate() {
        // $60/day against a $560 limit runs dry after ~9.3 days.
        let records = (0..<7).map { spend(60, on: "2026-08-\(24 + $0)") }
        let projection = make(records: records, limit: 560, now: "2026-08-30")

        XCTAssertEqual(projection.dailyBurn, 60, accuracy: 0.001)
        XCTAssertEqual(projection.pace, .willOverspend)

        // $420 spent, $140 left, $60/day -> crosses on the 3rd day from today.
        XCTAssertEqual(projection.runOutDate, date("2026-09-02"))
        XCTAssertEqual(projection.daysShort(calendar: calendar), 4)
    }

    func testAlreadyOverBudget() {
        let records = [spend(700, on: "2026-08-25")]
        let projection = make(records: records, limit: 560, now: "2026-08-30")

        XCTAssertEqual(projection.pace, .alreadyOver)
        // Reported as the day it actually crossed, not today.
        XCTAssertEqual(projection.runOutDate, date("2026-08-25"))
        XCTAssertLessThan(projection.dailyAllowance, 0)
    }

    func testUncategorizedSpendIsExcluded() {
        // Carried over from the server: a purchase doesn't move the budget
        // until you say what it was.
        let categorized = spend(100, on: "2026-08-25")
        let uncategorized = BudgetCalculator.SpendRecord(
            categoryID: nil, amountInHomeCurrency: 500, timestamp: date("2026-08-25")
        )
        let projection = make(records: [categorized, uncategorized], limit: 560, now: "2026-08-26")

        XCTAssertEqual(projection.spent, 100, accuracy: 0.001)
    }

    func testSpendOutsideThePeriodIsExcluded() {
        let inside = spend(100, on: "2026-08-25")
        let before = spend(999, on: "2026-08-20")
        let after = spend(999, on: "2026-09-10")
        let projection = make(records: [inside, before, after], limit: 560, now: "2026-08-26")

        XCTAssertEqual(projection.spent, 100, accuracy: 0.001)
    }

    func testNoSpendYet() {
        let projection = make(records: [], limit: 560, now: "2026-08-24")

        XCTAssertEqual(projection.spent, 0)
        XCTAssertEqual(projection.dailyBurn, 0)
        XCTAssertEqual(projection.pace, .onTrack)
        XCTAssertNil(projection.runOutDate)
        // The whole limit spread across all 14 days.
        XCTAssertEqual(projection.dailyAllowance, 40, accuracy: 0.001)
    }

    func testZeroLimitNeverReportsRunningOut() {
        // No budget set yet shouldn't render as "you're broke".
        let projection = make(records: [spend(50, on: "2026-08-25")], limit: 0, now: "2026-08-26")

        XCTAssertNil(projection.runOutDate)
        XCTAssertEqual(projection.pace, .onTrack)
    }

    func testActualSeriesIsCumulativeAndStartsAtZero() throws {
        let records = [
            spend(10, on: "2026-08-24"),
            spend(20, on: "2026-08-25"),
            spend(30, on: "2026-08-27"),
        ]
        let projection = make(records: records, limit: 560, now: "2026-08-27")
        let amounts = projection.actualSeries.map(\.amount)

        XCTAssertEqual(amounts.first, 0, "the line should begin at the origin")
        XCTAssertEqual(try XCTUnwrap(amounts.last), 60, accuracy: 0.001)
        // Cumulative means never decreasing.
        XCTAssertEqual(amounts, amounts.sorted())
        // A zero point plus one per elapsed day.
        XCTAssertEqual(projection.actualSeries.count, 5)
    }

    func testProjectedSeriesContinuesFromTodaysActualTotal() throws {
        let records = (0..<3).map { spend(50, on: "2026-08-\(24 + $0)") }
        let projection = make(records: records, limit: 560, now: "2026-08-26")

        XCTAssertEqual(
            try XCTUnwrap(projection.projectedSeries.first?.amount),
            projection.spent, accuracy: 0.001,
            "the projection must start where the actual line ends, not float away from it"
        )
        XCTAssertEqual(projection.projectedSeries.first?.date, date("2026-08-26"))
        XCTAssertEqual(projection.projectedSeries.last?.date, period.lastDay(calendar: calendar))
    }

    func testDailyAllowance() {
        let records = [spend(280, on: "2026-08-25")]
        // Half the budget gone with 8 days to go: $280 over 8 days.
        let projection = make(records: records, limit: 560, now: "2026-08-30")

        XCTAssertEqual(projection.dailyAllowance, 35, accuracy: 0.001)
    }
}
