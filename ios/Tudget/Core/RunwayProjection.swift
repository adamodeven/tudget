import Foundation

/// Projects where the current period ends up if you keep spending at the pace
/// you've set so far.
///
/// This is the thing a plain "$310 of $600 spent" number can't tell you: five
/// days into a fortnight, $310 spent isn't reassuring at all. The projection
/// turns pace into a date -- "at this rate you're out on the 3rd, three days
/// before the period ends" -- which is a fact you can act on.
struct RunwayProjection: Equatable, Sendable {

    /// One point on the cumulative-spend chart.
    struct Point: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// Money actually spent, up to and including today.
            case actual
            /// Where the current pace takes you between today and period end.
            case projected
            /// The straight line from zero to the limit -- perfectly even
            /// spending, shown as the reference to judge pace against.
            case onPace
        }

        let date: Date
        let amount: Double
        let kind: Kind

        var id: String { "\(kind)-\(date.timeIntervalSince1970)" }
    }

    enum Pace: Equatable, Sendable {
        /// Projected to finish the period within budget.
        case onTrack
        /// Projected to overspend, but not yet over.
        case willOverspend
        /// Already past the limit.
        case alreadyOver

        var isTrouble: Bool { self != .onTrack }
    }

    let period: BudgetPeriod
    let limit: Double
    let spent: Double
    let homeCurrency: String

    /// Average spend per elapsed day so far.
    let dailyBurn: Double
    /// Where `dailyBurn` lands you by the end of the period.
    let projectedTotal: Double
    /// The day the money runs out at this pace, if that happens on or before
    /// the period ends. Nil means you finish the period with money left.
    let runOutDate: Date?
    /// What you can spend per remaining day and still land exactly on budget.
    /// Negative when you're already over.
    let dailyAllowance: Double
    let pace: Pace

    let actualSeries: [Point]
    let projectedSeries: [Point]
    let onPaceSeries: [Point]

    /// Every series together, for a single Swift Charts `ForEach`.
    var allPoints: [Point] { actualSeries + projectedSeries + onPaceSeries }

    /// Days between the run-out date and the end of the period. Positive means
    /// you run dry with that many days still to go.
    func daysShort(calendar: Calendar = .current) -> Int? {
        guard let runOutDate else { return nil }
        let last = period.lastDay(calendar: calendar)
        let days = calendar.dateComponents([.day], from: runOutDate, to: last).day ?? 0
        return max(0, days)
    }
}

// MARK: - Building

extension RunwayProjection {

    /// Builds the projection for a period from its categorized spend.
    ///
    /// `records` may contain purchases outside the period; they're filtered
    /// out here so callers can pass the whole ledger.
    static func make(
        period: BudgetPeriod,
        limit: Double,
        records: [BudgetCalculator.SpendRecord],
        homeCurrency: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> RunwayProjection {

        let inPeriod = records
            .filter { period.contains($0.timestamp, calendar: calendar) }
            .filter { $0.categoryID != nil }

        let spent = inPeriod.reduce(0) { $0 + $1.amountInHomeCurrency }
        let totalDays = period.dayCount(calendar: calendar)
        let elapsedDays = period.elapsedDays(asOf: now, calendar: calendar)
        let remainingDays = period.remainingDays(asOf: now, calendar: calendar)

        let dailyBurn = elapsedDays > 0 ? spent / Double(elapsedDays) : 0
        let projectedTotal = dailyBurn * Double(totalDays)

        let remaining = limit - spent
        let dailyAllowance = remainingDays > 0
            ? remaining / Double(remainingDays)
            : remaining

        // --- Series ---------------------------------------------------------

        let actualSeries = cumulativeByDay(
            records: inPeriod, period: period, upTo: now, calendar: calendar
        )

        let today = min(calendar.startOfDay(for: now), period.lastDay(calendar: calendar))
        let daysAfterToday = period.daysAfterToday(asOf: now, calendar: calendar)

        var projectedSeries: [Point] = []
        if daysAfterToday > 0, dailyBurn > 0 {
            // Starts at today's actual total so the projected line continues
            // the actual one rather than floating away from it.
            projectedSeries.append(Point(date: today, amount: spent, kind: .projected))
            for dayOffset in 1...daysAfterToday {
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: today) else { break }
                projectedSeries.append(
                    Point(date: date, amount: spent + dailyBurn * Double(dayOffset), kind: .projected)
                )
            }
        }

        let onPaceSeries: [Point] = limit > 0
            ? [
                Point(date: period.start, amount: 0, kind: .onPace),
                Point(date: period.lastDay(calendar: calendar), amount: limit, kind: .onPace),
              ]
            : []

        // --- Run-out date ---------------------------------------------------

        let runOutDate = computeRunOutDate(
            spent: spent,
            limit: limit,
            dailyBurn: dailyBurn,
            projectedTotal: projectedTotal,
            today: today,
            period: period,
            actualSeries: actualSeries,
            calendar: calendar
        )

        let pace: Pace
        if spent > limit, limit > 0 {
            pace = .alreadyOver
        } else if runOutDate != nil {
            pace = .willOverspend
        } else {
            pace = .onTrack
        }

        return RunwayProjection(
            period: period,
            limit: limit,
            spent: spent,
            homeCurrency: homeCurrency,
            dailyBurn: dailyBurn,
            projectedTotal: projectedTotal,
            runOutDate: runOutDate,
            dailyAllowance: dailyAllowance,
            pace: pace,
            actualSeries: actualSeries,
            projectedSeries: projectedSeries,
            onPaceSeries: onPaceSeries
        )
    }

    /// Cumulative spend at the end of each elapsed day, starting from a zero
    /// point at the period start so the chart line begins at the origin.
    private static func cumulativeByDay(
        records: [BudgetCalculator.SpendRecord],
        period: BudgetPeriod,
        upTo now: Date,
        calendar: Calendar
    ) -> [Point] {
        var totalsByDay: [Date: Double] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.timestamp)
            totalsByDay[day, default: 0] += record.amountInHomeCurrency
        }

        let lastDay = min(calendar.startOfDay(for: now), period.lastDay(calendar: calendar))
        guard lastDay >= period.start else {
            return [Point(date: period.start, amount: 0, kind: .actual)]
        }

        var points: [Point] = [Point(date: period.start, amount: 0, kind: .actual)]
        var running = 0.0
        var day = period.start

        while day <= lastDay {
            running += totalsByDay[day] ?? 0
            points.append(Point(date: day, amount: running, kind: .actual))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        return points
    }

    /// The day cumulative spend crosses the limit -- looked up in the actual
    /// series when it's already happened, extrapolated from the burn rate when
    /// it hasn't. Nil if it doesn't happen before the period ends.
    private static func computeRunOutDate(
        spent: Double,
        limit: Double,
        dailyBurn: Double,
        projectedTotal: Double,
        today: Date,
        period: BudgetPeriod,
        actualSeries: [Point],
        calendar: Calendar
    ) -> Date? {
        guard limit > 0 else { return nil }

        if spent >= limit {
            return actualSeries.first(where: { $0.amount >= limit })?.date ?? today
        }

        guard dailyBurn > 0 else { return nil }

        // Money that lasts exactly to the end of the period hasn't run out --
        // that's landing on budget, which is the goal, not a warning. Only an
        // actual projected overshoot counts.
        guard projectedTotal > limit + 0.005 else { return nil }

        let daysUntilDry = (limit - spent) / dailyBurn
        // Round up: you run out on the day the total *crosses* the limit.
        let wholeDays = Int(daysUntilDry.rounded(.up))
        guard let date = calendar.date(byAdding: .day, value: wholeDays, to: today) else { return nil }

        return date <= period.lastDay(calendar: calendar) ? date : nil
    }
}

// MARK: - Copy

extension RunwayProjection {

    /// The line under the pace headline.
    ///
    /// A fragment rather than a sentence, and the same shape in every state:
    /// where the period lands you, and by how much. `paceHeadline` sits right
    /// above it and already says whether that's a forecast or a fact, so this
    /// line only has to carry the number.
    func summaryLine(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch pace {
        case .alreadyOver:
            // "already" is what separates this from the projected overspend
            // above it: that one hasn't happened yet, this one has.
            return "\(Currency.formatCompact(spent - limit, code: homeCurrency)) over already"

        case .willOverspend:
            return "\(Currency.formatCompact(projectedTotal - limit, code: homeCurrency)) over"

        case .onTrack:
            // Once the period is done the projection is just the total, and
            // the number worth showing is what actually went unspent.
            let remainingDays = period.remainingDays(asOf: now, calendar: calendar)
            let left = remainingDays > 0 ? limit - projectedTotal : limit - spent
            // The run-out date rounds up to a whole day, so a period can be
            // on track and still project a hair over the limit. Never report
            // that as a negative amount left.
            return "\(Currency.formatCompact(max(0, left), code: homeCurrency)) under"
        }
    }

    /// The short form the widgets and notifications use.
    var paceHeadline: String {
        switch pace {
        case .alreadyOver: return "Over budget"
        case .willOverspend: return "Spending too fast"
        case .onTrack: return "On track"
        }
    }
}
