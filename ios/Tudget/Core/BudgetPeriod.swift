import Foundation

/// How long a budget cycle runs.
///
/// The app is built around a fortnight because a month is too long a window to
/// extrapolate from while you're spending -- two weeks in, "I've spent $310 of
/// $600" is a number you can act on. Weekly and monthly are here because the
/// maths generalises for free and it's a setting worth being able to change
/// your mind about.
enum BudgetPeriodLength: String, Codable, CaseIterable, Identifiable {
    case weekly
    case biweekly
    case monthly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weekly: return "Weekly"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Monthly"
        }
    }

    /// Fixed length in days, or nil for calendar months, which vary.
    var fixedDayCount: Int? {
        switch self {
        case .weekly: return 7
        case .biweekly: return 14
        case .monthly: return nil
        }
    }
}

/// One budget cycle: a half-open date range `[start, end)`.
struct BudgetPeriod: Equatable, Identifiable, Sendable {

    let start: Date
    /// Exclusive -- the instant the next period begins.
    let end: Date

    var id: Date { start }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        return day >= start && day < end
    }

    /// Total days in the cycle.
    func dayCount(calendar: Calendar = .current) -> Int {
        max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
    }

    /// Days already begun, counting today as elapsed. Always at least 1 so
    /// burn-rate maths never divides by zero on day one.
    func elapsedDays(asOf now: Date = Date(), calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: now)
        guard today >= start else { return 0 }
        guard today < end else { return dayCount(calendar: calendar) }
        let elapsed = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return max(1, elapsed + 1)
    }

    /// Days left *including today*, because today's money is still unspent.
    ///
    /// Getting this off by one matters more than it looks: it's the divisor
    /// for "safe to spend per day", so excluding today would quietly hand you
    /// a daily allowance you can't actually afford. Zero once the period is
    /// genuinely over -- on the final day this is 1, not 0.
    func remainingDays(asOf now: Date = Date(), calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: now)
        guard today < end else { return 0 }
        guard today >= start else { return dayCount(calendar: calendar) }
        return dayCount(calendar: calendar) - elapsedDays(asOf: now, calendar: calendar) + 1
    }

    /// Days strictly after today -- what the projection extrapolates over.
    func daysAfterToday(asOf now: Date = Date(), calendar: Calendar = .current) -> Int {
        max(0, remainingDays(asOf: now, calendar: calendar) - 1)
    }

    /// The last day you can still spend on, i.e. the day before `end`.
    func lastDay(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -1, to: end) ?? end
    }

    /// How far through the cycle we are, 0...1.
    func fractionElapsed(asOf now: Date = Date(), calendar: Calendar = .current) -> Double {
        let total = Double(dayCount(calendar: calendar))
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(elapsedDays(asOf: now, calendar: calendar)) / total))
    }
}

// MARK: - Deriving periods from an anchor

enum BudgetPeriodCalculator {

    /// The period containing `date`.
    ///
    /// Fixed-length cycles tile forwards *and backwards* from `anchor` in
    /// exact-day steps, so a fortnight that starts on a Monday keeps starting
    /// on a Monday indefinitely, and history from before the anchor still
    /// falls into a well-defined period.
    static func period(
        containing date: Date,
        anchor: Date,
        length: BudgetPeriodLength,
        calendar: Calendar = .current
    ) -> BudgetPeriod {
        let day = calendar.startOfDay(for: date)

        guard let step = length.fixedDayCount else {
            return monthPeriod(containing: day, calendar: calendar)
        }

        let anchorDay = calendar.startOfDay(for: anchor)
        let offset = calendar.dateComponents([.day], from: anchorDay, to: day).day ?? 0

        // Floor division, so dates before the anchor land in the right
        // earlier block rather than truncating toward zero.
        let index = Int(floor(Double(offset) / Double(step)))

        let start = calendar.date(byAdding: .day, value: index * step, to: anchorDay) ?? anchorDay
        let end = calendar.date(byAdding: .day, value: step, to: start) ?? start
        return BudgetPeriod(start: start, end: end)
    }

    private static func monthPeriod(containing day: Date, calendar: Calendar) -> BudgetPeriod {
        let components = calendar.dateComponents([.year, .month], from: day)
        let start = calendar.date(from: components) ?? day
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? day
        return BudgetPeriod(start: start, end: end)
    }

    /// The period immediately before or after `period`.
    static func adjacent(
        to period: BudgetPeriod,
        offset: Int,
        anchor: Date,
        length: BudgetPeriodLength,
        calendar: Calendar = .current
    ) -> BudgetPeriod {
        guard offset != 0 else { return period }

        let reference: Date
        if let step = length.fixedDayCount {
            reference = calendar.date(
                byAdding: .day, value: offset * step, to: period.start
            ) ?? period.start
        } else {
            reference = calendar.date(
                byAdding: .month, value: offset, to: period.start
            ) ?? period.start
        }

        return self.period(containing: reference, anchor: anchor, length: length, calendar: calendar)
    }

    /// The Monday on or before `date` -- the default anchor, since a cycle
    /// that starts mid-week is harder to hold in your head than one that
    /// starts when the week does.
    static func mondayOnOrBefore(_ date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        // Calendar weekday is 1=Sunday ... 7=Saturday, so Monday is 2.
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday - 2 + 7) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day) ?? day
    }
}

// MARK: - Display

extension BudgetPeriod {

    /// "Aug 24 – Sep 6", or "Aug 24 – Sep 6, 2026" when the period doesn't sit
    /// in the current year.
    func formattedRange(calendar: Calendar = .current, now: Date = Date()) -> String {
        let last = lastDay(calendar: calendar)

        let sameYearAsNow = calendar.component(.year, from: start)
            == calendar.component(.year, from: now)

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "MMM d"

        let startText = formatter.string(from: start)
        let endText = formatter.string(from: last)

        if sameYearAsNow {
            return "\(startText) – \(endText)"
        }
        formatter.dateFormat = "MMM d, yyyy"
        return "\(startText) – \(formatter.string(from: last))"
    }

    /// "6 days left", "Last day", "Ends today".
    func remainingDescription(asOf now: Date = Date(), calendar: Calendar = .current) -> String {
        let remaining = remainingDays(asOf: now, calendar: calendar)
        switch remaining {
        case 0: return "Period over"
        case 1: return "Last day"
        default: return "\(remaining) days left"
        }
    }
}
