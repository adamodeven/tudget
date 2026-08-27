import SwiftUI
import SwiftData
import PhotosUI

/// Logging a purchase by hand.
///
/// Two modes, because both are genuinely faster in different moments: "Quick"
/// is the one-line phrase the Python version took over SMS ("Trader Joe's $34
/// groceries"), parsed live; "Details" is the structured form for when you
/// want to attach a receipt or backdate something.
struct AddPurchaseView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\BudgetCategory.sortOrder), SortDescriptor(\BudgetCategory.name)])
    private var categories: [BudgetCategory]

    enum Mode: String, CaseIterable {
        case quick = "Quick"
        case details = "Details"
    }

    @State private var mode: Mode = .quick
    @State private var quickText = ""

    @State private var merchant = ""
    @State private var amountText = ""
    @State private var currencyCode = ""
    @State private var selectedCategory: BudgetCategory?
    @State private var timestamp = Date()
    @State private var note = ""

    @State private var photoItem: PhotosPickerItem?
    @State private var receiptData: Data?
    @State private var isSaving = false

    /// What the quick-entry line currently parses to, recomputed as you type.
    private var quickParse: PurchaseTextParser.QuickEntry {
        PurchaseTextParser.parseQuickEntry(
            quickText,
            categoryNames: categories.map(\.name),
            defaultCurrency: settings.homeCurrency
        )
    }

    private var effectiveAmount: Double? {
        switch mode {
        case .quick: return quickParse.amount
        case .details: return CurrencyParser.parseNumber(amountText)
        }
    }

    private var effectiveMerchant: String {
        switch mode {
        case .quick: return quickParse.merchant ?? ""
        case .details: return merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var effectiveCurrency: String {
        switch mode {
        case .quick: return quickParse.currencyCode
        case .details: return currencyCode.isEmpty ? settings.homeCurrency : currencyCode
        }
    }

    private var effectiveCategory: BudgetCategory? {
        switch mode {
        case .quick:
            guard let name = quickParse.category else { return nil }
            return categories.first { $0.name == name }
        case .details:
            return selectedCategory
        }
    }

    private var canSave: Bool {
        guard let amount = effectiveAmount, amount > 0 else { return false }
        return !effectiveMerchant.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)

                if mode == .quick {
                    quickSection
                } else {
                    detailsSection
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                            } else {
                                Text("Log purchase").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
            .navigationTitle("Add purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if currencyCode.isEmpty { currencyCode = settings.homeCurrency }
            }
        }
    }

    // MARK: - Quick mode

    private var quickSection: some View {
        Section {
            TextField("Trader Joe's $34 groceries", text: $quickText, axis: .vertical)
                .font(.title3)
                .textInputAutocapitalization(.words)

            if !quickText.isEmpty {
                QuickParsePreview(
                    parse: quickParse,
                    matchedCategory: effectiveCategory,
                    homeCurrency: settings.homeCurrency
                )
            }
        } footer: {
            Text("Type a merchant, an amount, and optionally a category. Any currency works — \"€12,47 lunch\", \"1200 JPY ramen\".")
        }
    }

    // MARK: - Details mode

    private var detailsSection: some View {
        Group {
            Section("Purchase") {
                TextField("Merchant", text: $merchant)
                    .textInputAutocapitalization(.words)

                HStack {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    Divider()
                    CurrencyPicker(selection: $currencyCode)
                        .labelsHidden()
                }

                DatePicker("When", selection: $timestamp, in: ...Date())
            }

            Section("Category") {
                CategoryPicker(categories: categories, selection: $selectedCategory)
            }

            Section("Optional") {
                TextField("Note", text: $note, axis: .vertical)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(
                        receiptData == nil ? "Attach receipt" : "Receipt attached",
                        systemImage: receiptData == nil ? "paperclip" : "checkmark.circle.fill"
                    )
                }
                .onChange(of: photoItem) { _, item in
                    Task { receiptData = try? await item?.loadTransferable(type: Data.self) }
                }

                if receiptData != nil {
                    Button("Remove receipt", role: .destructive) {
                        receiptData = nil
                        photoItem = nil
                    }
                }
            }
        }
    }

    // MARK: - Save

    private func save() async {
        guard let amount = effectiveAmount, !effectiveMerchant.isEmpty else { return }
        isSaving = true

        await LedgerActions.addTransaction(
            in: context,
            merchant: effectiveMerchant,
            amount: amount,
            currencyCode: effectiveCurrency,
            category: effectiveCategory,
            receiptData: mode == .details ? receiptData : nil,
            note: mode == .details && !note.isEmpty ? note : nil,
            source: .manual,
            timestamp: mode == .details ? timestamp : Date(),
            settings: settings
        )

        isSaving = false
        dismiss()
    }
}

// MARK: - Supporting views

private struct QuickParsePreview: View {

    let parse: PurchaseTextParser.QuickEntry
    let matchedCategory: BudgetCategory?
    let homeCurrency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Merchant", parse.merchant ?? "—")
            row(
                "Amount",
                parse.amount.map { Currency.format($0, code: parse.currencyCode) } ?? "—"
            )
            row("Category", matchedCategory?.displayName ?? "Ask me later")
        }
        .font(.footnote)
        .padding(.vertical, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }
}

struct CurrencyPicker: View {

    @Binding var selection: String

    private var codes: [String] {
        Currency.pickerCodes(deviceCode: Currency.deviceCurrencyCode)
    }

    var body: some View {
        Picker("Currency", selection: $selection) {
            ForEach(codes, id: \.self) { code in
                Text(code).tag(code)
            }
        }
        .pickerStyle(.menu)
    }
}

struct CategoryPicker: View {

    let categories: [BudgetCategory]
    @Binding var selection: BudgetCategory?

    var body: some View {
        if categories.isEmpty {
            Text("No categories yet — add some in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories) { category in
                        CategoryChip(
                            title: category.displayName,
                            isSelected: selection?.uuid == category.uuid
                        ) {
                            selection = selection?.uuid == category.uuid ? nil : category
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct CategoryChip: View {

    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected ? Color.tudgetAccent : Color.secondary.opacity(0.15),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
