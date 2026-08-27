import XCTest
@testable import Tudget

/// The fortnight maths. Worth real coverage: the app's every number is scoped
/// to "this period", so an off-by-one here silently misreports every total.
final class BudgetPeriodTests: XCTestCase {

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

    // Monday 24 Aug 2026.
    private var anchor: Date { date("2026-08-24") }

    func testPeriodStartsOnAnchor() {
        let period = BudgetPeriodCalculator.period(
            containing: anchor, anchor: anchor, length: .biweekly, calendar: calendar
        )
        XCTAssertEqual(period.start, anchor)
        XCTAssertEqual(period.end, date("2026-09-07"))
        XCTAssertEqual(period.dayCount(calendar: calendar), 14)
    }

    func testDateLateInPeriodStaysInSamePeriod() {
        // The 13th day is still inside the first fortnight.
        let period = BudgetPeriodCalculator.period(
            containing: date("2026-09-06"), anchor: anchor, length: .biweekly, calendar: calendar
        )
        XCTAssertEqual(period.start, anchor)
    }

    func testDayAfterPeriodRollsToNext() {
        let period = BudgetPeriodCalculator.period(
            containing: date("2026-09-07"), anchor: anchor, length: .biweekly, calendar: calendar
        )
        XCTAssertEqual(period.start, date("2026-09-07"))
        XCTAssertEqual(period.end, date("2026-09-21"))
    }

    /// Floor division, not truncation toward zero -- history from before the
    /// anchor has to land in a well-defined earlier period.
    func testDatesBeforeAnchorTileBackwards() {
        let period = BudgetPeriodCalculator.period(
            containing: date("2026-08-23"), anchor: anchor, length: .biweekly, calendar: calendar
        )
        XCTAssertEqual(period.start, date("2026-08-10"))
        XCTAssertEqual(period.end, anchor)
    }

    func testWellBeforeAnchorStillLandsOnAMonday() {
        let period = BudgetPeriodCalculator.period(
            containing: date("2026-05-03"), anchor: anchor, length: .biweekly, calendar: calendar
        )
        XCTAssertEqual(calendar.component(.weekday, from: period.start), 2, "should start on a Monday")
        XCTAssertTrue(period.contains(date("2026-05-03"), calendar: calendar))
    }

    /// A fortnight containing a DST transition is still 14 days, not 13.96.
    func testPeriodSpanningDSTIsStillFourteenDays() {
        // US DST ends Sunday 1 Nov 2026.
        let period = BudgetPeriodCalculator.period(
            containing: date("2026-11-02"), anchor: anchor, length: .biweekly, calendar: calendar
        )
        XCTAssertEqual(period.dayCount(calendar: calendar), 14)
        XCTAssertEqual(calendar.component(.weekday, from: period.start), 2)
    }

    func testElapsedAndRemainingDays() {
        let period = BudgetPeriodCalculator.period(
            containing: anchor, anchor: anchor, length: .biweekly, calendar: calendar
        )

        // Day one counts as elapsed, so burn-rate maths never divides by zero.
        // Remaining *includes* today, so all 14 days are still spendable.
        XCTAssertEqual(period.elapsedDays(asOf: anchor, calendar: calendar), 1)
        XCTAssertEqual(period.remainingDays(asOf: anchor, calendar: calendar), 14)
        XCTAssertEqual(period.daysAfterToday(asOf: anchor, calendar: calendar), 13)

        XCTAssertEqual(period.elapsedDays(asOf: date("2026-08-30"), calendar: calendar), 7)
        XCTAssertEqual(period.remainingDays(asOf: date("2026-08-30"), calendar: calendar), 8)

        // The final day still has a day left on it -- it reads "Last day",
        // not "Period over".
        XCTAssertEqual(period.elapsedDays(asOf: date("2026-09-06"), calendar: calendar), 14)
        XCTAssertEqual(period.remainingDays(asOf: date("2026-09-06"), calendar: calendar), 1)
        XCTAssertEqual(period.remainingDescription(asOf: date("2026-09-06"), calendar: calendar), "Last day")

        // Once it's genuinely over, nothing is left.
        XCTAssertEqual(period.remainingDays(asOf: date("2026-09-07"), calendar: calendar), 0)
        XCTAssertEqual(period.remainingDescription(asOf: date("2026-09-07"), calendar: calendar), "Period over")
    }

    func testContainsIsHalfOpen() {
        let period = BudgetPeriodCalculator.period(
            containing: anchor, anchor: anchor, length: .biweekly, calendar: calendar
        )
        XCTAssertTrue(period.contains(anchor, calendar: calendar))
        XCTAssertTrue(period.contains(date("2026-09-06"), calendar: calendar))
        XCTAssertFalse(period.contains(date("2026-09-07"), calendar: calendar), "end is exclusive")
        XCTAssertFalse(period.contains(date("2026-08-23"), calendar: calendar))
    }

    func testAdjacentPeriods() {
        let period = BudgetPeriodCalculator.period(
            containing: anchor, anchor: anchor, length: .biweekly, calendar: calendar
        )
        let next = BudgetPeriodCalculator.adjacent(
            to: period, offset: 1, anchor: anchor, length: .biweekly, calendar: calendar
        )
        let previous = BudgetPeriodCalculator.adjacent(
            to: period, offset: -1, anchor: anchor, length: .biweekly, calendar: calendar
        )

        XCTAssertEqual(next.start, date("2026-09-07"))
        XCTAssertEqual(previous.start, date("2026-08-10"))
        XCTAssertEqual(previous.end, period.start, "periods must abut with no gap")
        XCTAssertEqual(period.end, next.start)
    }

    func testWeeklyAndMonthly() {
        let weekly = BudgetPeriodCalculator.period(
            containing: date("2026-08-27"), anchor: anchor, length: .weekly, calendar: calendar
        )
        XCTAssertEqual(weekly.start, date("2026-08-24"))
        XCTAssertEqual(weekly.dayCount(calendar: calendar), 7)

        let monthly = BudgetPeriodCalculator.period(
            containing: date("2026-08-27"), anchor: anchor, length: .monthly, calendar: calendar
        )
        XCTAssertEqual(monthly.start, date("2026-08-01"))
        XCTAssertEqual(monthly.end, date("2026-09-01"))
        XCTAssertEqual(monthly.dayCount(calendar: calendar), 31)
    }

    func testMondayOnOrBefore() {
        // A Monday is its own answer.
        XCTAssertEqual(
            BudgetPeriodCalculator.mondayOnOrBefore(date("2026-08-24"), calendar: calendar),
            date("2026-08-24")
        )
        // Friday -> that Monday.
        XCTAssertEqual(
            BudgetPeriodCalculator.mondayOnOrBefore(date("2026-08-28"), calendar: calendar),
            date("2026-08-24")
        )
        // Sunday is the end of the week, so it goes back six days, not forward.
        XCTAssertEqual(
            BudgetPeriodCalculator.mondayOnOrBefore(date("2026-08-30"), calendar: calendar),
            date("2026-08-24")
        )
    }
}
