import SwiftUI
import SwiftData

struct TransactionDetailView: View {

    let transaction: Transaction

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var showingDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metric.cardSpacing) {
                amountCard
                categoryCard
                if let filename = transaction.receiptFilename {
                    receiptCard(filename)
                }
                detailsCard
                deleteButton
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.bottom, 90)
        }
        .background(AmbientBackground(tint: transaction.category?.tint.color ?? .blue))
        .navigationTitle(transaction.displayMerchant)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete this purchase?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Ledger.delete(transaction, context: context)
                dismiss()
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private var amountCard: some View {
        VStack(spacing: 4) {
            Text(transaction.formattedAmount)
                .font(Theme.hero)
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            if let home = transaction.formattedHomeAmount {
                Text("\(home) at the rate when it was logged")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Category")
                .font(.subheadline.weight(.semibold))

            GlassEffectContainer(spacing: 8) {
                FlowLayout(spacing: 8) {
                    ForEach(categories) { category in
                        let isSelected = transaction.category?.uuid == category.uuid
                        Button {
                            withAnimation(.smooth) {
                                Ledger.categorize(
                                    transaction,
                                    as: isSelected ? nil : category,
                                    context: context
                                )
                            }
                        } label: {
                            Text(category.displayName)
                                .font(.subheadline)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .glassChip(tint: category.tint.color, selected: isSelected)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func receiptCard(_ filename: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Receipt")
                .font(.subheadline.weight(.semibold))

            if let url = AppGroup.receiptURL(for: filename),
               let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .clipShape(.rect(cornerRadius: Theme.Metric.tightRadius))
            } else {
                Text("The image couldn't be loaded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var detailsCard: some View {
        VStack(spacing: 10) {
            StatRow(
                label: "When",
                value: transaction.timestamp.formatted(.dateTime.weekday().month().day().hour().minute())
            )
            Divider()
            StatRow(label: "Added by", value: transaction.source.label)
            if let note = transaction.note, !note.isEmpty {
                Divider()
                StatRow(label: "Note", value: note)
            }
        }
        .glassCard()
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showingDeleteConfirmation = true
        } label: {
            Label("Delete purchase", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .tint(.red)
    }
}

/// One category's spend for a period, reached by tapping its dashboard tile.
struct CategoryDetailView: View {

    let categoryID: UUID
    let period: BudgetPeriod

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context

    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Transaction.timestamp, order: .reverse) private var transactions: [Transaction]

    private var category: BudgetCategory? {
        categories.first { $0.uuid == categoryID }
    }

    private var items: [Transaction] {
        transactions.filter {
            $0.category?.uuid == categoryID && period.contains($0.timestamp)
        }
    }

    private var budget: BudgetCalculator.CategoryBudget? {
        BudgetCalculator.summary(
            categories: Ledger.limits(from: categories),
            records: Ledger.spendRecords(from: transactions),
            period: period,
            homeCurrency: settings.homeCurrencyCode
        )
        .categories.first { $0.id == categoryID }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metric.cardSpacing) {
                if let budget {
                    header(budget)
                }

                if items.isEmpty {
                    EmptyHint(
                        systemImage: "tray",
                        title: "Nothing here yet",
                        message: "No purchases in this category this period."
                    )
                    .glassCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(items) { transaction in
                            NavigationLink {
                                TransactionDetailView(transaction: transaction)
                            } label: {
                                TransactionRow(transaction: transaction)
                            }
                            .buttonStyle(.plain)

                            if transaction.id != items.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .glassCard(radius: Theme.Metric.tightRadius)
                }
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.bottom, 90)
        }
        .background(AmbientBackground(tint: category?.tint.color ?? .blue))
        .navigationTitle(category?.name ?? "Category")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ budget: BudgetCalculator.CategoryBudget) -> some View {
        VStack(spacing: 12) {
            ZStack {
                BudgetRing(
                    fraction: budget.fractionUsed,
                    tint: budget.tint.color,
                    lineWidth: 12,
                    isOver: budget.isOverBudget
                )
                VStack(spacing: 0) {
                    Text(budget.emoji.isEmpty ? "" : budget.emoji)
                        .font(.title3)
                    Text("\(Int(budget.rawFractionUsed * 100))%")
                        .font(.headline)
                        .monospacedDigit()
                }
            }
            .frame(width: 110, height: 110)

            Text(budget.isOverBudget
                 ? "\(Currency.format(abs(budget.remaining), code: settings.homeCurrencyCode)) over"
                 : "\(Currency.format(budget.remaining, code: settings.homeCurrencyCode)) left")
                .font(Theme.title)
                .foregroundStyle(budget.isOverBudget ? .red : .primary)

            Text("\(Currency.formatCompact(budget.spent, code: settings.homeCurrencyCode)) of \(Currency.formatCompact(budget.limit, code: settings.homeCurrencyCode)) · \(period.formattedRange())")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .glassCard()
    }
}
