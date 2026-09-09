import SwiftUI
import SwiftData

struct DashboardView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context

    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Transaction.timestamp, order: .reverse) private var transactions: [Transaction]

    /// 0 is the current period, -1 the one before, and so on.
    @State private var periodOffset = 0

    private var period: BudgetPeriod {
        settings.period(offsetBy: periodOffset)
    }

    private var summary: BudgetCalculator.PeriodSummary {
        BudgetCalculator.summary(
            categories: Ledger.limits(from: categories),
            records: Ledger.spendRecords(from: transactions),
            period: period,
            homeCurrency: settings.homeCurrencyCode
        )
    }

    private var projection: RunwayProjection {
        RunwayProjection.make(
            period: period,
            limit: summary.totalLimit,
            records: Ledger.spendRecords(from: transactions),
            homeCurrency: settings.homeCurrencyCode
        )
    }

    private var uncategorized: [Transaction] {
        transactions.filter { $0.category == nil && period.contains($0.timestamp) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metric.cardSpacing) {
                    periodHeader
                    heroCard

                    if !uncategorized.isEmpty {
                        needsCategorySection
                    }

                    categorySection
                }
                .padding(.horizontal, Theme.Metric.gutter)
                .padding(.bottom, 90)
            }
            .background(AmbientBackground(tint: Theme.color(for: projection.pace)))
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Period header

    private var periodHeader: some View {
        HStack {
            Button {
                withAnimation(.smooth) { periodOffset -= 1 }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.glass)

            VStack(spacing: 2) {
                Text(period.formattedRange())
                    .font(.subheadline.weight(.semibold))
                Text(periodOffset == 0 ? period.remainingDescription() : "Past period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button {
                withAnimation(.smooth) { periodOffset += 1 }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.glass)
            .disabled(periodOffset >= 0)
            .opacity(periodOffset >= 0 ? 0.4 : 1)
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text(summary.isOverBudget ? "Over budget by" : "Left to spend")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(Currency.format(abs(summary.totalRemaining), code: summary.homeCurrency))
                    .font(Theme.hero)
                    .foregroundStyle(summary.isOverBudget ? .red : .primary)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: summary.totalRemaining)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Text("of \(Currency.formatCompact(summary.totalLimit, code: summary.homeCurrency)) this period")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            spendBar

            if periodOffset == 0 {
                paceRow
            }
        }
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    private var spendBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)

                Capsule()
                    .fill(Theme.color(for: projection.pace).gradient)
                    .frame(width: max(6, proxy.size.width * summary.fractionUsed))
                    .animation(.smooth(duration: 0.5), value: summary.fractionUsed)

                // Where you'd be if you'd spent perfectly evenly. The gap
                // between this and the fill is the whole story at a glance.
                if periodOffset == 0, summary.totalLimit > 0 {
                    Capsule()
                        .fill(.primary.opacity(0.55))
                        .frame(width: 2, height: 16)
                        .offset(x: proxy.size.width * period.fractionElapsed())
                }
            }
        }
        .frame(height: 12)
    }

    private var paceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: projection.pace == .onTrack
                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(projection.summaryLine())
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.color(for: projection.pace))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Needs a category

    /// Carried over from the SMS flow: a purchase is logged the moment it
    /// happens and told what it was afterwards, so capture is never blocked on
    /// making a decision.
    private var needsCategorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs a category", systemImage: "questionmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            ForEach(uncategorized) { transaction in
                Button {
                    router.categorizing = transaction
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transaction.displayMerchant)
                                .font(.subheadline.weight(.medium))
                            Text(transaction.timestamp, format: .dateTime.weekday().month().day())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(transaction.formattedAmount)
                            .font(Theme.figure)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                if transaction.id != uncategorized.last?.id {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tintedGlassCard(.orange)
    }

    // MARK: - Categories

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Categories")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            if summary.categories.isEmpty {
                EmptyHint(
                    systemImage: "square.grid.2x2",
                    title: "No categories yet",
                    message: "Add some in Settings to start tracking against a budget."
                )
                .glassCard()
            } else {
                // A container lets neighbouring glass cards blend into each
                // other rather than each rendering its own hard edge.
                GlassEffectContainer(spacing: Theme.Metric.cardSpacing) {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: Theme.Metric.cardSpacing),
                                  GridItem(.flexible(), spacing: Theme.Metric.cardSpacing)],
                        spacing: Theme.Metric.cardSpacing
                    ) {
                        ForEach(summary.categories) { budget in
                            NavigationLink {
                                CategoryDetailView(categoryID: budget.id, period: period)
                            } label: {
                                CategoryTile(
                                    budget: budget,
                                    fractionElapsed: periodOffset == 0 ? period.fractionElapsed() : 1,
                                    homeCurrency: summary.homeCurrency
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Category tile

struct CategoryTile: View {

    let budget: BudgetCalculator.CategoryBudget
    let fractionElapsed: Double
    let homeCurrency: String

    private var health: BudgetCalculator.BudgetHealth {
        budget.health(fractionElapsed: fractionElapsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    BudgetRing(
                        fraction: budget.fractionUsed,
                        tint: budget.tint.color,
                        lineWidth: 7,
                        isOver: budget.isOverBudget
                    )
                    Text(budget.emoji.isEmpty ? "•" : budget.emoji)
                        .font(.system(size: 15))
                }
                .frame(width: 42, height: 42)

                Spacer(minLength: 0)

                if health == .over || health == .critical {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Theme.color(for: health))
                        .font(.footnote)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(budget.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(budget.isOverBudget
                     ? "\(Currency.formatCompact(abs(budget.remaining), code: homeCurrency)) over"
                     : "\(Currency.formatCompact(budget.remaining, code: homeCurrency)) left")
                    .font(.footnote)
                    .foregroundStyle(budget.isOverBudget ? .red : .secondary)
                    .contentTransition(.numericText())

                Text("of \(Currency.formatCompact(budget.limit, code: homeCurrency))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tintedGlassCard(budget.tint.color, radius: Theme.Metric.tightRadius)
        .contentShape(.rect)
    }
}
