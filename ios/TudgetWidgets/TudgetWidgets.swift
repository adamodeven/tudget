import SwiftUI
import WidgetKit
import SwiftData
import AppIntents

// MARK: - Bundle

@main
struct TudgetWidgetBundle: WidgetBundle {
    var body: some Widget {
        BudgetWidget()
        QuickAddControl()
        ScreenshotControl()
    }
}

// MARK: - Timeline

/// A flattened view of the current period, small enough to hand to a widget.
struct BudgetEntry: TimelineEntry {
    let date: Date
    let remaining: Double
    let limit: Double
    let spent: Double
    let fractionUsed: Double
    let fractionElapsed: Double
    let currency: String
    let periodLabel: String
    let remainingLabel: String
    let paceHeadline: String
    let isOverBudget: Bool
    let isBehindPace: Bool
    let uncategorizedCount: Int
    let topCategories: [CategorySnapshot]

    struct CategorySnapshot: Identifiable {
        let id: UUID
        let name: String
        let emoji: String
        let tint: CategoryTint
        let remaining: Double
        let fractionUsed: Double
        let isOver: Bool
    }

    /// Shown in the widget gallery and before the store has been read.
    static let placeholder = BudgetEntry(
        date: Date(),
        remaining: 412, limit: 600, spent: 188,
        fractionUsed: 0.31, fractionElapsed: 0.42,
        currency: "USD",
        periodLabel: "Aug 24 – Sep 6",
        remainingLabel: "9 days left",
        paceHeadline: "On track",
        isOverBudget: false, isBehindPace: false,
        uncategorizedCount: 0,
        topCategories: []
    )
}

struct BudgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> BudgetEntry { .placeholder }

    // WidgetKit calls these on the main thread, but they aren't declared as
    // main-actor, and the SwiftData context they reach for is main-actor
    // bound — so the isolation is asserted rather than hopped, which would
    // deadlock a synchronous completion handler.
    func getSnapshot(in context: Context, completion: @escaping (BudgetEntry) -> Void) {
        MainActor.assumeIsolated { completion(makeEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BudgetEntry>) -> Void) {
        MainActor.assumeIsolated {
            let entry = makeEntry()
            // The ledger pushes a reload on every change, so this is only the
            // safety net that keeps day-based maths (days left, pace) honest.
            let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    @MainActor
    private func makeEntry() -> BudgetEntry {
        let settings = AppSettings.shared
        let context = ModelContext(LedgerStore.shared)
        let period = settings.period()

        let summary = Ledger.summary(for: period, context: context, settings: settings)
        let projection = Ledger.projection(for: period, context: context, settings: settings)

        // Whatever is closest to its limit is what you need to know about.
        let ranked = summary.categories
            .filter { $0.limit > 0 }
            .sorted { $0.rawFractionUsed > $1.rawFractionUsed }
            .prefix(3)
            .map {
                BudgetEntry.CategorySnapshot(
                    id: $0.id, name: $0.name, emoji: $0.emoji, tint: $0.tint,
                    remaining: $0.remaining, fractionUsed: $0.fractionUsed,
                    isOver: $0.isOverBudget
                )
            }

        return BudgetEntry(
            date: Date(),
            remaining: summary.totalRemaining,
            limit: summary.totalLimit,
            spent: summary.totalSpent,
            fractionUsed: summary.fractionUsed,
            fractionElapsed: period.fractionElapsed(),
            currency: summary.homeCurrency,
            periodLabel: period.formattedRange(),
            remainingLabel: period.remainingDescription(),
            paceHeadline: projection.paceHeadline,
            isOverBudget: summary.isOverBudget,
            isBehindPace: projection.pace.isTrouble,
            uncategorizedCount: summary.uncategorizedCount,
            topCategories: Array(ranked)
        )
    }
}

// MARK: - Widget

struct BudgetWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TudgetBudgetWidget", provider: BudgetProvider()) { entry in
            BudgetWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                // Tapping goes straight to entry, because the point of seeing
                // the number is usually that you're about to spend. The one
                // exception is when you're already overspending, where the
                // pace chart is the more useful place to land.
                .widgetURL(entry.isBehindPace ? QuickAction.pace.url : QuickAction.quickAdd.url)
        }
        .configurationDisplayName("Budget")
        .description("What's left this cycle, and how your pace is going.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

struct BudgetWidgetView: View {

    @Environment(\.widgetFamily) private var family
    let entry: BudgetEntry

    private var statusColor: Color {
        if entry.isOverBudget { return .red }
        if entry.isBehindPace { return .orange }
        return .green
    }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .systemMedium: medium
        default: small
        }
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.isOverBudget ? "Over by" : "Left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: entry.isBehindPace
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }

            Text(Currency.formatCompact(abs(entry.remaining), code: entry.currency))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(entry.isOverBudget ? .red : .primary)

            progressBar

            Text(entry.remainingLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var medium: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.isOverBudget ? "Over by" : "Left to spend")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(Currency.formatCompact(abs(entry.remaining), code: entry.currency))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(entry.isOverBudget ? .red : .primary)

                progressBar

                Label(entry.paceHeadline, systemImage: entry.isBehindPace
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(statusColor)

                Text(entry.remainingLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !entry.topCategories.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(entry.topCategories) { category in
                        HStack(spacing: 6) {
                            // Emoji + name, so the row never depends on colour
                            // alone to say which category it is.
                            Text(category.emoji.isEmpty ? "•" : category.emoji)
                                .font(.caption2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Capsule()
                                    .fill(.quaternary)
                                    .frame(height: 3)
                                    .overlay(alignment: .leading) {
                                        GeometryReader { proxy in
                                            Capsule()
                                                .fill(category.isOver ? Color.red : category.tint.color)
                                                .frame(width: proxy.size.width * category.fractionUsed)
                                        }
                                    }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var progressBar: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(statusColor)
                            .frame(width: max(3, proxy.size.width * entry.fractionUsed))
                        // Where the cycle has got to — the gap between this and
                        // the fill is the actual signal.
                        Capsule()
                            .fill(.primary.opacity(0.6))
                            .frame(width: 1.5, height: 7)
                            .offset(x: proxy.size.width * entry.fractionElapsed, y: -1)
                    }
                }
            }
    }

    // MARK: Lock Screen

    private var circular: some View {
        Gauge(value: min(entry.fractionUsed, 1)) {
            Image(systemName: "dollarsign")
        } currentValueLabel: {
            Text(Currency.formatCompact(abs(entry.remaining), code: entry.currency))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.isOverBudget ? "Over budget" : "Left this cycle")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Currency.formatCompact(abs(entry.remaining), code: entry.currency))
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("\(entry.paceHeadline) · \(entry.remainingLabel)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var inline: some View {
        Text("\(Currency.formatCompact(abs(entry.remaining), code: entry.currency)) \(entry.isOverBudget ? "over" : "left")")
    }
}

// MARK: - Control Centre

/// A Control Centre / Lock Screen button that goes straight to entry.
///
/// This is the fastest capture path the platform allows: swipe, tap, type.
struct QuickAddControl: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TudgetQuickAddControl") {
            ControlWidgetButton(action: OpenQuickAddIntent()) {
                Label("Add Purchase", systemImage: "plus.circle.fill")
            }
        }
        .displayName("Add a Purchase")
        .description("Log a purchase in Tudget.")
    }
}

struct ScreenshotControl: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "TudgetScreenshotControl") {
            ControlWidgetButton(action: OpenScreenshotImportIntent()) {
                Label("Scan Purchase", systemImage: "camera.viewfinder")
            }
        }
        .displayName("Scan a Purchase")
        .description("Read a purchase off a screenshot.")
    }
}
