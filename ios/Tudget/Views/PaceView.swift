import SwiftUI
import SwiftData
import Charts

/// "Am I going to make it to the end of the period?"
///
/// The chart plots cumulative spend against the limit. Three things share one
/// y-axis (never two): what you've actually spent, where your current pace
/// takes you, and the straight line you'd follow spending perfectly evenly.
///
/// Past and future are distinguished by *line style*, not by hue -- the single
/// colour in the plot is a reserved status colour that means on-track /
/// overspending / over, and it always ships beside an icon and a worded
/// headline rather than carrying the meaning alone.
struct PaceView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context

    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Transaction.timestamp, order: .reverse) private var transactions: [Transaction]

    @State private var selectedDate: Date?

    private var period: BudgetPeriod { settings.period() }

    private var limit: Double {
        categories.reduce(0) { $0 + $1.periodLimit }
    }

    private var projection: RunwayProjection {
        RunwayProjection.make(
            period: period,
            limit: limit,
            records: Ledger.spendRecords(from: transactions),
            homeCurrency: settings.homeCurrencyCode
        )
    }

    private var summary: BudgetCalculator.PeriodSummary {
        BudgetCalculator.summary(
            categories: Ledger.limits(from: categories),
            records: Ledger.spendRecords(from: transactions),
            period: period,
            homeCurrency: settings.homeCurrencyCode
        )
    }

    private var statusColor: Color { Theme.color(for: projection.pace) }

    /// The three line styles, defined once and used by both the plot and the
    /// key below it -- that's what keeps the key honest.
    private enum Stroke {
        static let spent = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        static let projected = StrokeStyle(lineWidth: 2, dash: [5, 4])
        static let evenPace = StrokeStyle(lineWidth: 1.5, dash: [2, 5])
    }

    /// Even-pace grey. A concrete colour rather than `.tertiary` so the key
    /// swatch resolves to exactly what the plot draws.
    private static let evenPaceColor = Color.secondary.opacity(0.55)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metric.cardSpacing) {
                    headline
                    chartCard
                    statsCard
                    categoryPaceCard
                }
                .padding(.horizontal, Theme.Metric.gutter)
                .padding(.bottom, 90)
            }
            .background(AmbientBackground(tint: statusColor))
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("Pace")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(spacing: 10) {
            // Status is carried by icon + words, never by colour alone.
            Label {
                Text(projection.paceHeadline)
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: projection.pace == .onTrack
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            }
            .foregroundStyle(statusColor)

            Text(projection.summaryLine())
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cumulative spend")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(period.formattedRange())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            chart
                .frame(height: 210)

            legend
        }
        .glassCard()
    }

    private var chart: some View {
        Chart {
            // The limit: a plain reference rule, direct-labeled, deliberately
            // recessive so it frames the data instead of competing with it.
            if limit > 0 {
                RuleMark(y: .value("Budget", limit))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text("Budget \(Currency.formatCompact(limit, code: projection.homeCurrency))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }

            // Even-spending reference. Neutral grey: it's scaffolding, not a
            // series with an identity.
            ForEach(projection.onPaceSeries) { point in
                LineMark(
                    x: .value("Day", point.date),
                    y: .value("Spend", point.amount),
                    series: .value("Series", "Even pace")
                )
                .lineStyle(Stroke.evenPace)
                .foregroundStyle(Self.evenPaceColor)
            }

            // What's actually been spent.
            ForEach(projection.actualSeries) { point in
                LineMark(
                    x: .value("Day", point.date),
                    y: .value("Spend", point.amount),
                    series: .value("Series", "Spent")
                )
                .lineStyle(Stroke.spent)
                .foregroundStyle(statusColor)
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("Day", point.date),
                    y: .value("Spend", point.amount),
                    series: .value("Series", "Spent")
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [statusColor.opacity(0.22), statusColor.opacity(0.01)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)
            }

            // Where the current pace takes you: same colour, dashed, because
            // it's the same measure, just not a fact yet.
            ForEach(projection.projectedSeries) { point in
                LineMark(
                    x: .value("Day", point.date),
                    y: .value("Spend", point.amount),
                    series: .value("Series", "Projected")
                )
                .lineStyle(Stroke.projected)
                .foregroundStyle(statusColor.opacity(0.65))
            }

            // The moment the money runs out.
            if let runOut = projection.runOutDate, limit > 0 {
                PointMark(
                    x: .value("Day", runOut),
                    y: .value("Spend", limit)
                )
                .symbolSize(90)
                .foregroundStyle(statusColor)
            }

            if let selectedDate, let value = amount(on: selectedDate) {
                RuleMark(x: .value("Day", selectedDate))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.quaternary)
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        VStack(spacing: 2) {
                            Text(selectedDate, format: .dateTime.month().day())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(Currency.format(value, code: projection.homeCurrency))
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .rect(cornerRadius: 8))
                    }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXScale(domain: period.start...period.lastDay())
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(Currency.formatCompact(amount, code: projection.homeCurrency))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xAxisDates) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                if let date = value.as(Date.self) {
                    // The final tick is the end of the period, so it sits on
                    // the plot's right edge, where a centred label hangs off
                    // and gets clipped to "Se...". Anchoring it trailing sets
                    // its right edge against the tick and moves it inward.
                    AxisValueLabel(anchor: date == xAxisDates.last ? .topTrailing : .top) {
                        Text(date, format: .dateTime.month(.abbreviated).day())
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The gridline dates, walked *backwards* from the last day so the axis
    /// always ends on the end of the period rather than stopping a few days
    /// short of it.
    ///
    /// At most five labels: enough to read the axis, few enough that they
    /// never collide. That matters more here than it normally would, because
    /// the last label is right-aligned and so reaches further left than a
    /// centred one does.
    private var xAxisDates: [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: period.start)
        let last = calendar.startOfDay(for: period.lastDay())
        let span = max(1, calendar.dateComponents([.day], from: start, to: last).day ?? 1)
        let strideDays = max(1, Int((Double(span) / 4).rounded(.up)))

        var dates: [Date] = []
        var day = last

        while day >= start {
            dates.append(day)
            guard let previous = calendar.date(byAdding: .day, value: -strideDays, to: day) else { break }
            day = previous
        }

        return dates.reversed()
    }

    private func amount(on date: Date) -> Double? {
        let day = Calendar.current.startOfDay(for: date)
        let candidates = projection.actualSeries + projection.projectedSeries
        return candidates
            .min(by: {
                abs($0.date.timeIntervalSince(day)) < abs($1.date.timeIntervalSince(day))
            })?
            .amount
    }

    /// Three series share the plot, so a legend is always present.
    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(statusColor, Stroke.spent, "Spent")
            legendItem(statusColor.opacity(0.65), Stroke.projected, "Projected")
            legendItem(Self.evenPaceColor, Stroke.evenPace, "Even pace")
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// A short stretch of the line itself, stroked with the very style the plot
    /// uses. The swatch is laid out at its true width, so it can never spill
    /// over the label beside it.
    private func legendItem(_ color: Color, _ stroke: StrokeStyle, _ label: String) -> some View {
        HStack(spacing: 6) {
            Path {
                $0.move(to: CGPoint(x: 0, y: 1))
                $0.addLine(to: CGPoint(x: Self.swatchWidth, y: 1))
            }
            .stroke(color, style: stroke)
            .frame(width: Self.swatchWidth, height: 2)

            Text(label)
        }
    }

    /// Wide enough that a dashed swatch reads as dashed and a dotted one as
    /// dotted, rather than as one stub of line.
    private static let swatchWidth: CGFloat = 20

    // MARK: - Stats

    private var statsCard: some View {
        VStack(spacing: 10) {
            StatRow(
                label: "Spent so far",
                value: Currency.format(projection.spent, code: projection.homeCurrency)
            )
            Divider()
            StatRow(
                label: "Average per day",
                value: Currency.format(projection.dailyBurn, code: projection.homeCurrency)
            )
            Divider()
            StatRow(
                label: "Safe to spend per day",
                value: Currency.format(max(0, projection.dailyAllowance), code: projection.homeCurrency),
                valueColor: projection.dailyAllowance <= 0 ? .red : .primary
            )
            Divider()
            StatRow(
                label: "Projected by \(period.lastDay().formatted(.dateTime.month().day()))",
                value: Currency.format(projection.projectedTotal, code: projection.homeCurrency),
                valueColor: projection.projectedTotal > limit ? .red : .primary
            )
        }
        .glassCard()
    }

    // MARK: - Per-category pace

    private var categoryPaceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By category")
                .font(.subheadline.weight(.semibold))

            if summary.categories.isEmpty {
                Text("No categories yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(summary.categories) { budget in
                    CategoryPaceRow(
                        budget: budget,
                        fractionElapsed: period.fractionElapsed(),
                        homeCurrency: summary.homeCurrency
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

/// One category's bar, with a tick showing where the period has got to.
///
/// The gap between the fill and the tick *is* the message: fill past the tick
/// means spending faster than the clock.
private struct CategoryPaceRow: View {

    let budget: BudgetCalculator.CategoryBudget
    let fractionElapsed: Double
    let homeCurrency: String

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(budget.displayName)
                    .font(.footnote.weight(.medium))
                Spacer()
                Text("\(Currency.formatCompact(budget.spent, code: homeCurrency)) / \(Currency.formatCompact(budget.limit, code: homeCurrency))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(budget.isOverBudget ? Color.red : budget.tint.color)
                        .frame(width: max(4, proxy.size.width * budget.fractionUsed))
                    Capsule()
                        .fill(.primary.opacity(0.5))
                        .frame(width: 1.5, height: 12)
                        .offset(x: proxy.size.width * min(1, fractionElapsed))
                }
            }
            .frame(height: 8)
        }
    }
}
