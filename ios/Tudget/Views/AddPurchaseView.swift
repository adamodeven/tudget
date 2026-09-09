import SwiftUI
import SwiftData

/// Confirm a spoken purchase, or type one in.
///
/// Two ways in, one screen. Holding the capture bar and speaking lands here on
/// the verify step: what was heard, big enough to read at arm's length, with
/// *Yes* and *Edit*. Everything else -- a swipe up on the capture bar, a
/// widget, a transcript with no amount in it -- lands on the fields, where the
/// amount and the merchant are two separate boxes rather than one line somebody
/// has to phrase correctly.
struct AddPurchaseView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    /// What opened the sheet, and with what.
    let request: PurchaseEntryRequest

    private enum Stage { case verifying, editing }
    private enum Field { case amount, merchant }

    @State private var stage: Stage = .editing
    @State private var merchant = ""
    @State private var amountText = ""
    @State private var currencyCode = ""
    @State private var pickedCategory: BudgetCategory?
    @State private var notice: String?
    @State private var showingDetails = false
    @State private var date = Date()
    @State private var note = ""
    @State private var isSaving = false
    /// Set once saved: the "what's left" line, shown briefly before dismissing.
    @State private var confirmation: String?

    @FocusState private var focus: Field?

    private var amount: Double {
        CurrencyParser.parseNumber(amountText) ?? 0
    }

    /// A purchase needs a category before it can be saved: an amount with no
    /// category is a number the budget can't do anything with.
    private var canSave: Bool { amount > 0 && pickedCategory != nil && !isSaving }

    var body: some View {
        NavigationStack {
            Group {
                if let confirmation {
                    confirmationView(confirmation)
                } else if stage == .verifying {
                    verifyStep
                } else {
                    editStep
                }
            }
            .background(AmbientBackground(tint: pickedCategory?.tint.color ?? .blue))
            .navigationTitle(stage == .verifying ? "Is this right?" : "Add a purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if stage == .editing, confirmation == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }
                            .disabled(!canSave)
                            .buttonStyle(.glassProminent)
                    }
                }
                // The decimal pad has no return key, so without this there's
                // no way back out of the amount field.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.regularMaterial)
        .onAppear(perform: applyRequest)
    }

    // MARK: - Verify

    /// The whole point of speaking a purchase is not having to look at the
    /// phone while you do it -- so this step is readable in one glance and
    /// answerable with one thumb.
    private var verifyStep: some View {
        VStack(spacing: Theme.Metric.cardSpacing) {
            Spacer(minLength: 0)

            if let heard = request.heard {
                Label("\u{201C}\(heard)\u{201D}", systemImage: "waveform")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(spacing: 6) {
                Text(Currency.format(amount, code: currencyCode))
                    .font(Theme.hero)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                Text(merchant.isEmpty ? "Unknown" : merchant)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)

                if let category = pickedCategory {
                    Text(category.displayName)
                        .font(.subheadline)
                        .glassChip(tint: category.tint.color, selected: true)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .glassCard()

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button {
                    Task { await save() }
                } label: {
                    Label("Yes, log it", systemImage: "checkmark")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(!canSave)

                Button {
                    withAnimation(.smooth) { stage = .editing }
                    focus = .amount
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(Theme.Metric.gutter)
    }

    // MARK: - Fields

    private var editStep: some View {
        ScrollView {
            VStack(spacing: Theme.Metric.cardSpacing) {
                if let notice { noticeCard(notice) }
                amountField
                merchantField
                categoryPicker
                detailsDisclosure
            }
            .padding(Theme.Metric.gutter)
        }
        .task {
            // A beat, so focus lands after the sheet's presentation animation
            // rather than fighting it.
            guard stage == .editing, focus == nil else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if focus == nil { focus = .amount }
        }
    }

    private func noticeCard(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.bubble")
            .font(.footnote)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tintedGlassCard(.orange, radius: Theme.Metric.tightRadius)
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Amount")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Currency", selection: $currencyCode) {
                    ForEach(Currency.pickerCodes(deviceCode: Currency.deviceCurrencyCode), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden()
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Currency.displaySymbol[currencyCode] ?? currencyCode)
                    .font(Theme.title)
                    .foregroundStyle(.secondary)

                TextField("0", text: $amountText)
                    .font(Theme.title)
                    // A price is digits and a decimal point and nothing else,
                    // so it gets the pad that is only those.
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: .amount)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var merchantField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Merchant")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Where", text: $merchant)
                .font(.title3)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focus, equals: .merchant)
                .submitLabel(.done)
                .onSubmit { focus = nil }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Category").font(.subheadline.weight(.semibold))
                Spacer()
                if pickedCategory == nil {
                    Text("Pick one to save")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GlassEffectContainer(spacing: 8) {
                FlowLayout(spacing: 8) {
                    ForEach(categories) { category in
                        let isSelected = pickedCategory?.uuid == category.uuid
                        Button {
                            withAnimation(.smooth) { pickedCategory = category }
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

    private func applyRequest() {
        guard currencyCode.isEmpty else { return }

        let draft = request.draft
        merchant = draft.merchant
        amountText = draft.amountText
        currencyCode = draft.currencyCode.isEmpty ? settings.homeCurrencyCode : draft.currencyCode
        if let name = draft.categoryName {
            pickedCategory = categories.first { $0.name == name }
        }
        notice = request.notice

        // Only a transcript we actually got an amount *and* a category out of
        // is worth putting on the verify step; anything else would be asking
        // "is this right?" about something still missing a required answer.
        if request.heard != nil, amount > 0, pickedCategory != nil {
            stage = .verifying
        } else {
            stage = .editing
            if let heard = request.heard, notice == nil {
                notice = "I heard \u{201C}\(heard)\u{201D} but couldn't pick an amount out of it."
            }
        }
    }

    private func save() async {
        guard amount > 0, let category = pickedCategory, !isSaving else { return }
        isSaving = true
        focus = nil

        await Ledger.record(
            merchant: merchant.isEmpty ? "Unknown" : merchant,
            amount: amount,
            currencyCode: currencyCode,
            category: category,
            note: note.isEmpty ? nil : note,
            timestamp: showingDetails ? date : Date(),
            source: request.heard == nil ? .manual : .voice,
            context: context,
            settings: settings
        )

        await BudgetNotifier.shared.refreshAlerts(context: context, settings: settings)

        confirmation = confirmationLine(for: category)

        try? await Task.sleep(for: .milliseconds(1600))
        dismiss()
    }

    private func confirmationLine(for category: BudgetCategory) -> String {
        let period = settings.period()
        let summary = BudgetCalculator.summary(
            categories: Ledger.limits(from: categories),
            records: Ledger.spendRecords(from: Ledger.transactions(in: period, context: context)),
            period: period,
            homeCurrency: settings.homeCurrencyCode
        )

        return BudgetCalculator.confirmationLine(for: category.uuid, summary: summary)
    }
}

// MARK: - What opens the sheet

/// A purchase on its way in, before it's a `Transaction`.
///
/// The amount is held as text rather than a number because that is what the
/// field edits, and because "12." is a real thing to be halfway through
/// typing.
struct PurchaseDraft: Equatable {
    var merchant = ""
    var amountText = ""
    /// Empty means "whatever the home currency is".
    var currencyCode = ""
    var categoryName: String?

    /// Builds a draft from what the parser made of a sentence.
    init(_ entry: PurchaseTextParser.QuickEntry) {
        merchant = entry.merchant ?? ""
        currencyCode = entry.currencyCode
        categoryName = entry.category
        if let amount = entry.amount, amount > 0 {
            amountText = String(
                format: "%.\(Currency.decimalPlaces(for: entry.currencyCode))f", amount
            )
        }
    }

    init() {}
}

/// Why the entry sheet is open, and what it should show first.
struct PurchaseEntryRequest: Identifiable, Equatable {

    let id = UUID()
    var draft = PurchaseDraft()
    /// The sentence dictation heard. Its presence is what puts the sheet on
    /// the verify step rather than straight into the fields.
    var heard: String?
    /// Shown above the fields: why we're typing rather than talking.
    var notice: String?

    /// Swiped up on the capture bar, or arrived from a widget.
    static var manual: Self { .init() }

    /// Held the capture bar and said something.
    static func heard(_ text: String, draft: PurchaseDraft) -> Self {
        .init(draft: draft, heard: text)
    }

    /// Held the capture bar, but the mic never got going.
    static func couldNotListen(_ reason: String) -> Self {
        .init(notice: reason)
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
