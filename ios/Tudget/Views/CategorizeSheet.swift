import SwiftUI
import SwiftData

/// "What was this?" — the categorize step, on its own.
///
/// This is the SMS reply flow rebuilt as a screen: a purchase already exists,
/// it just needs telling what it was, and the answer comes back as the same
/// "here's what's left" line the server used to text.
struct CategorizeSheet: View {

    let transaction: Transaction

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var confirmation: String?
    @State private var chosenTint: Color = .blue

    var body: some View {
        NavigationStack {
            Group {
                if let confirmation {
                    result(confirmation)
                } else {
                    picker
                }
            }
            .background(AmbientBackground(tint: chosenTint))
            .navigationTitle("What was this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(.regularMaterial)
    }

    private var picker: some View {
        VStack(spacing: Theme.Metric.cardSpacing) {
            VStack(spacing: 4) {
                Text(transaction.displayMerchant)
                    .font(.title3.weight(.semibold))
                Text(transaction.formattedAmount)
                    .font(Theme.title)
                if let home = transaction.formattedHomeAmount {
                    Text(home)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .glassCard()

            GlassEffectContainer(spacing: 10) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 110), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(categories) { category in
                        Button {
                            choose(category)
                        } label: {
                            VStack(spacing: 4) {
                                Text(category.emoji.isEmpty ? "•" : category.emoji)
                                    .font(.title2)
                                Text(category.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .glassEffect(
                                .regular.tint(category.tint.color.opacity(0.28)).interactive(),
                                in: .rect(cornerRadius: Theme.Metric.tightRadius)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Metric.gutter)
    }

    private func result(_ line: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: line)
            Text(line)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choose(_ category: BudgetCategory) {
        withAnimation(.smooth) { chosenTint = category.tint.color }

        Ledger.categorize(transaction, as: category, context: context)

        let period = settings.period(containing: transaction.timestamp)
        let summary = BudgetCalculator.summary(
            categories: Ledger.limits(from: categories),
            records: Ledger.spendRecords(from: Ledger.transactions(in: period, context: context)),
            period: period,
            homeCurrency: settings.homeCurrencyCode
        )

        confirmation = BudgetCalculator.confirmationLine(for: category.uuid, summary: summary)

        Task {
            await BudgetNotifier.shared.refreshAlerts(context: context, settings: settings)
            try? await Task.sleep(for: .milliseconds(1700))
            dismiss()
        }
    }
}
