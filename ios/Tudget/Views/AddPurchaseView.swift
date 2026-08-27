import SwiftUI
import SwiftData

/// Log a purchase from one line of text.
///
/// The whole screen is built around the assumption that you're standing at a
/// counter: the field is focused before the sheet finishes animating in, the
/// parse updates as you type so you can see it understood you, and Return
/// saves. Everything else -- date, note, receipt -- is behind a disclosure and
/// out of the way.
struct AddPurchaseView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]
    @Query(sort: \Transaction.timestamp, order: .reverse) private var transactions: [Transaction]

    /// Pre-filled when arriving from a screenshot rather than the keyboard.
    var prefill: PurchaseDraft?

    @State private var text = ""
    @State private var pickedCategory: BudgetCategory?
    @State private var showingDetails = false
    @State private var date = Date()
    @State private var note = ""
    @State private var isSaving = false
    /// Set once saved: the "what's left" line, shown briefly before dismissing.
    @State private var confirmation: String?

    @FocusState private var fieldFocused: Bool

    private var parsed: PurchaseTextParser.QuickEntry {
        PurchaseTextParser.parseQuickEntry(
            text,
            categoryNames: categories.map(\.name),
            defaultCurrency: settings.homeCurrencyCode
        )
    }

    /// The category actually used: an explicit tap always beats the parse.
    private var effectiveCategory: BudgetCategory? {
        if let pickedCategory { return pickedCategory }
        guard let name = parsed.category else { return nil }
        return categories.first { $0.name == name }
    }

    private var canSave: Bool {
        (parsed.amount ?? 0) > 0 && !isSaving
    }

    var body: some View {
        NavigationStack {
            Group {
                if let confirmation {
                    confirmationView(confirmation)
                } else {
                    form
                }
            }
            .background(AmbientBackground(tint: effectiveCategory?.tint.color ?? .blue))
            .navigationTitle("Add a purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.regularMaterial)
        .onAppear(perform: applyPrefill)
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(spacing: Theme.Metric.cardSpacing) {
                entryField
                if (parsed.amount ?? 0) > 0 { parseSummary }
                categoryPicker
                detailsDisclosure
            }
            .padding(Theme.Metric.gutter)
        }
    }

    private var entryField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Trader Joe's $34 groceries", text: $text, axis: .vertical)
                .font(.title3)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit { if canSave { Task { await save() } } }

            Text("Merchant, amount, and a category — in any order.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .task {
            // A beat, so focus lands after the sheet's presentation animation
            // rather than fighting it.
            try? await Task.sleep(for: .milliseconds(350))
            fieldFocused = true
        }
    }

    /// Shows what was understood, so a misparse is visible before you save
    /// rather than discovered in the ledger a week later.
    private var parseSummary: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Merchant").font(.caption2).foregroundStyle(.secondary)
                Text(parsed.merchant ?? "—")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Amount").font(.caption2).foregroundStyle(.secondary)
                Text(Currency.format(parsed.amount ?? 0, code: parsed.currencyCode))
                    .font(Theme.figure)
                    .contentTransition(.numericText())
            }
        }
        .animation(.smooth, value: parsed)
        .glassCard(radius: Theme.Metric.tightRadius)
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Category").font(.subheadline.weight(.semibold))
                Spacer()
                if effectiveCategory == nil {
                    Text("Optional — you can set it later")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GlassEffectContainer(spacing: 8) {
                FlowLayout(spacing: 8) {
                    ForEach(categories) { category in
                        let isSelected = effectiveCategory?.uuid == category.uuid
                        Button {
                            withAnimation(.smooth) {
                                pickedCategory = isSelected ? nil : category
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
    }

    private var detailsDisclosure: some View {
        DisclosureGroup(isExpanded: $showingDetails) {
            VStack(spacing: 12) {
                DatePicker("When", selection: $date, displayedComponents: [.date, .hourAndMinute])
                TextField("Note", text: $note)
            }
            .padding(.top, 8)
        } label: {
            Label("Details", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.medium))
        }
        .glassCard(radius: Theme.Metric.tightRadius)
    }

    // MARK: - Confirmation

    /// The same sentence the server used to text back after categorizing.
    private func confirmationView(_ line: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: line)

            Text(line)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func applyPrefill() {
        guard let prefill, text.isEmpty else { return }
        text = prefill.asQuickEntryText
        date = prefill.timestamp
        if let name = prefill.categoryName {
            pickedCategory = categories.first { $0.name == name }
        }
    }

    private func save() async {
        guard let amount = parsed.amount, amount > 0 else { return }
        isSaving = true

        let category = effectiveCategory

        await Ledger.record(
            merchant: parsed.merchant ?? "Unknown",
            amount: amount,
            currencyCode: parsed.currencyCode,
            category: category,
            note: note.isEmpty ? nil : note,
            timestamp: showingDetails ? date : Date(),
            source: prefill == nil ? .quickEntry : .screenshot,
            context: context,
            settings: settings
        )

        await BudgetNotifier.shared.refreshAlerts(context: context, settings: settings)

        confirmation = confirmationLine(for: category)

        try? await Task.sleep(for: .milliseconds(1600))
        dismiss()
    }

    private func confirmationLine(for category: BudgetCategory?) -> String {
        let period = settings.period()
        let summary = BudgetCalculator.summary(
            categories: Ledger.limits(from: categories),
            records: Ledger.spendRecords(from: Ledger.transactions(in: period, context: context)),
            period: period,
            homeCurrency: settings.homeCurrencyCode
        )

        guard let category else {
            return "Logged. Tell me what it was when you get a moment."
        }
        return BudgetCalculator.confirmationLine(for: category.uuid, summary: summary)
    }
}

/// What a screenshot (or any non-keyboard source) hands to the entry screen.
struct PurchaseDraft: Equatable {
    var merchant: String?
    var amount: Double?
    var currencyCode: String
    var categoryName: String?
    var timestamp: Date = Date()
    var receiptFilename: String?

    /// Rendered back into the one-line grammar, so the screenshot path and the
    /// typed path converge on the same editable text.
    var asQuickEntryText: String {
        var parts: [String] = []
        if let merchant { parts.append(merchant) }
        if let amount { parts.append(Currency.format(amount, code: currencyCode)) }
        return parts.joined(separator: " ")
    }
}

/// Wraps chips onto as many lines as they need.
///
/// `LazyVGrid` can't do this -- category names vary in width and a fixed
/// column count leaves ragged gaps.
struct FlowLayout: Layout {

    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var rowHeights: [CGFloat] = [0]

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let current = rows[rows.count - 1]
            let needed = current == 0 ? size.width : current + spacing + size.width

            if needed > maxWidth, current > 0 {
                rows.append(size.width)
                rowHeights.append(size.height)
            } else {
                rows[rows.count - 1] = needed
                rowHeights[rowHeights.count - 1] = max(rowHeights[rowHeights.count - 1], size.height)
            }
        }

        let height = rowHeights.reduce(0, +) + spacing * CGFloat(max(0, rowHeights.count - 1))
        return CGSize(width: proposal.width ?? rows.max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
