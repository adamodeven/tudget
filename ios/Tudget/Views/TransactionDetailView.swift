import SwiftUI
import SwiftData
import UIKit

/// The fast path for the app's most common chore: a transaction landed
/// uncategorized (shared in, read off a screenshot), and all it needs is a tap.
struct CategorizeSheet: View {

    let transaction: Transaction

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\BudgetCategory.sortOrder), SortDescriptor(\BudgetCategory.name)])
    private var categories: [BudgetCategory]

    @Query private var allTransactions: [Transaction]

    @State private var confirmation: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text(transaction.formattedAmount)
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                    Text(transaction.merchant)
                        .font(.headline)
                    if let home = transaction.formattedHomeAmount {
                        Text("\(home) in \(settings.homeCurrency)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 12)

                if let confirmation {
                    Text(confirmation)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.tudgetAccent)
                        .padding(.horizontal)
                        .transition(.opacity)
                }

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        ForEach(categories) { category in
                            Button {
                                assign(category)
                            } label: {
                                Text(category.displayName)
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                    .background(
                                        transaction.category?.uuid == category.uuid
                                            ? Color.tudgetAccent
                                            : Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 12)
                                    )
                                    .foregroundStyle(
                                        transaction.category?.uuid == category.uuid ? .white : .primary
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }

                Spacer(minLength: 0)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Categorize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
        }
    }

    /// Assigning shows the same "what's left" line the SMS version texted back,
    /// then dismisses -- the number is the whole point of categorizing.
    private func assign(_ category: BudgetCategory) {
        transaction.category = category
        transaction.syncedAt = nil
        try? context.save()

        let summary = BudgetCalculator.summary(
            categories: categories.map {
                BudgetCalculator.CategoryLimit(
                    id: $0.uuid, name: $0.name, emoji: $0.emoji, monthlyLimit: $0.monthlyLimit
                )
            },
            records: allTransactions.map {
                BudgetCalculator.SpendRecord(
                    categoryID: $0.category?.uuid,
                    amountInHomeCurrency: $0.amountInHomeCurrency,
                    timestamp: $0.timestamp
                )
            }
        )

        withAnimation {
            confirmation = BudgetCalculator.confirmationLine(
                for: category.uuid, summary: summary, homeCurrency: settings.homeCurrency
            )
        }

        Task {
            try? await Task.sleep(for: .seconds(1.6))
            dismiss()
        }
    }
}

struct TransactionDetailView: View {

    @Bindable var transaction: Transaction

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\BudgetCategory.sortOrder), SortDescriptor(\BudgetCategory.name)])
    private var categories: [BudgetCategory]

    @State private var amountText = ""
    @State private var showingDeleteConfirm = false

    var body: some View {
        Form {
            Section("Purchase") {
                TextField("Merchant", text: $transaction.merchant)

                HStack {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    Divider()
                    CurrencyPicker(selection: $transaction.currencyCode)
                        .labelsHidden()
                }

                DatePicker("When", selection: $transaction.timestamp, in: ...Date())
            }

            Section("Category") {
                CategoryPicker(categories: categories, selection: $transaction.category)
            }

            Section("Details") {
                LabeledContent("Source", value: transaction.source.label)
                if transaction.currencyCode != settings.homeCurrency {
                    LabeledContent(
                        "In \(settings.homeCurrency)",
                        value: Currency.format(
                            transaction.amountInHomeCurrency, code: settings.homeCurrency
                        )
                    )
                }
                TextField("Note", text: Binding(
                    get: { transaction.note ?? "" },
                    set: { transaction.note = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
            }

            if let filename = transaction.receiptFilename,
               let data = SharedStore.receiptData(filename),
               let image = UIImage(data: data) {
                Section("Receipt") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            Section {
                Button("Delete purchase", role: .destructive) {
                    showingDeleteConfirm = true
                }
            }
        }
        .navigationTitle(transaction.merchant)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            amountText = String(
                format: "%.\(Currency.decimalPlaces(for: transaction.currencyCode))f",
                transaction.amount
            )
        }
        .onDisappear {
            Task { await commitAmountIfChanged() }
        }
        .confirmationDialog(
            "Delete this purchase?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                LedgerActions.delete(transaction, in: context)
                dismiss()
            }
        }
    }

    /// The amount is edited as text, so it's written back (and re-converted)
    /// only once, on the way out.
    private func commitAmountIfChanged() async {
        guard let parsed = CurrencyParser.parseNumber(amountText), parsed > 0 else { return }
        guard parsed != transaction.amount
            || transaction.homeCurrencyCode != settings.homeCurrency else {
            try? context.save()
            return
        }
        await LedgerActions.updateAmount(
            transaction,
            amount: parsed,
            currencyCode: transaction.currencyCode,
            in: context,
            settings: settings
        )
    }
}
