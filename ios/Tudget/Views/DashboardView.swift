import SwiftUI
import SwiftData

struct DashboardView: View {

    @Binding var showingAddPurchase: Bool

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context

    @Query(sort: [SortDescriptor(\BudgetCategory.sortOrder), SortDescriptor(\BudgetCategory.name)])
    private var categories: [BudgetCategory]

    @Query(sort: \Transaction.timestamp, order: .reverse)
    private var transactions: [Transaction]

    @State private var showingScreenshotImport = false
    @State private var categorizing: Transaction?

    private var summary: BudgetCalculator.MonthSummary {
        BudgetCalculator.summary(
            categories: categories.map {
                BudgetCalculator.CategoryLimit(
                    id: $0.uuid, name: $0.name, emoji: $0.emoji, monthlyLimit: $0.monthlyLimit
                )
            },
            records: transactions.map {
                BudgetCalculator.SpendRecord(
                    categoryID: $0.category?.uuid,
                    amountInHomeCurrency: $0.amountInHomeCurrency,
                    timestamp: $0.timestamp
                )
            }
        )
    }

    /// This month's transactions that still need a category -- the app's one
    /// piece of outstanding work, so it sits at the top.
    private var needsCategory: [Transaction] {
        transactions.filter {
            !$0.isCategorized && BudgetCalculator.isInMonth($0.timestamp, of: Date())
        }
    }

    private var recent: [Transaction] {
        Array(transactions.prefix(5))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    MonthTotalCard(summary: summary, currencyCode: settings.homeCurrency)

                    quickActions

                    if !needsCategory.isEmpty {
                        needsCategorySection
                    }

                    if categories.isEmpty {
                        EmptyStateView(
                            systemImage: "tray",
                            title: "No categories yet",
                            message: "Set up your budget in Settings to start tracking spend by category."
                        )
                    } else {
                        categorySection
                    }

                    if !recent.isEmpty {
                        recentSection
                    }
                }
                .padding()
            }
            .navigationTitle(monthTitle)
            .background(Color(.systemGroupedBackground))
            .sheet(isPresented: $showingScreenshotImport) {
                ScreenshotImportView()
            }
            .sheet(item: $categorizing) { transaction in
                CategorizeSheet(transaction: transaction)
            }
        }
    }

    private var monthTitle: String {
        Date().formatted(.dateTime.month(.wide).year())
    }

    // MARK: - Sections

    private var quickActions: some View {
        HStack(spacing: 12) {
            QuickActionButton(
                title: "Add purchase",
                systemImage: "plus.circle.fill",
                action: { showingAddPurchase = true }
            )
            QuickActionButton(
                title: "From screenshot",
                systemImage: "camera.viewfinder",
                action: { showingScreenshotImport = true }
            )
        }
    }

    private var needsCategorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: "Needs a category",
                subtitle: "\(Currency.formatCompact(summary.uncategorizedSpent, code: settings.homeCurrency)) not counted yet"
            )

            VStack(spacing: 0) {
                ForEach(needsCategory) { transaction in
                    Button {
                        categorizing = transaction
                    } label: {
                        TransactionRow(transaction: transaction, showsChevron: true)
                    }
                    .buttonStyle(.plain)

                    if transaction.uuid != needsCategory.last?.uuid {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Categories")

            VStack(spacing: 18) {
                ForEach(summary.categories) { category in
                    BudgetBar(
                        title: category.displayName,
                        spent: category.spent,
                        limit: category.limit,
                        fractionUsed: category.fractionUsed,
                        isOver: category.isOverBudget,
                        currencyCode: settings.homeCurrency
                    )
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Recent")

            VStack(spacing: 0) {
                ForEach(recent) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        TransactionRow(transaction: transaction, showsChevron: true)
                    }
                    .buttonStyle(.plain)

                    if transaction.uuid != recent.last?.uuid {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - Pieces

private struct MonthTotalCard: View {

    let summary: BudgetCalculator.MonthSummary
    let currencyCode: String

    private var headline: String {
        if summary.totalLimit == 0 {
            return Currency.formatCompact(summary.totalSpent, code: currencyCode)
        }
        return Currency.formatCompact(abs(summary.totalRemaining), code: currencyCode)
    }

    private var caption: String {
        if summary.totalLimit == 0 {
            return "spent this month"
        }
        return summary.isOverBudget
            ? "over your \(Currency.formatCompact(summary.totalLimit, code: currencyCode)) budget"
            : "left of \(Currency.formatCompact(summary.totalLimit, code: currencyCode))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(headline)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(summary.isOverBudget ? Color.tudgetOver : Color.primary)
                .contentTransition(.numericText())

            Text(caption)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if summary.totalLimit > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(Color.budgetStatus(
                                fractionUsed: summary.fractionUsed,
                                isOver: summary.isOverBudget
                            ))
                            .frame(width: max(0, geometry.size.width * summary.fractionUsed))
                    }
                }
                .frame(height: 10)
                .padding(.top, 4)

                Text("\(Currency.formatCompact(summary.totalSpent, code: currencyCode)) spent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct QuickActionButton: View {

    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2)
                Text(title)
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.tudgetAccent)
    }
}

struct SectionHeader: View {

    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TransactionRow: View {

    let transaction: Transaction
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transaction.source.systemImage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.secondary.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(transaction.timestamp.formatted(.dateTime.month().day()))
                    if let category = transaction.category {
                        Text("·")
                        Text(category.displayName).lineLimit(1)
                    } else {
                        Text("·")
                        Text("Uncategorized").foregroundStyle(Color.tudgetWarning)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(transaction.formattedAmount)
                    .font(.subheadline.weight(.semibold))
                if let home = transaction.formattedHomeAmount {
                    Text(home)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .contentShape(Rectangle())
    }
}
