import SwiftUI
import SwiftData
import PhotosUI

/// Import a purchase from a screenshot of a bank notification.
///
/// The OCR result is always shown as an *editable draft*, never saved blind,
/// and the raw recognized text is one tap away — so a bad parse is obvious and
/// fixable rather than a mysterious wrong number in the ledger later.
struct ScreenshotImportView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var state: ImportState = .idle

    @State private var merchant = ""
    @State private var amountText = ""
    @State private var currencyCode = ""
    @State private var pickedCategory: BudgetCategory?
    @State private var rawText = ""
    @State private var showingRawText = false
    @State private var confirmation: String?

    private enum ImportState: Equatable {
        case idle
        case reading
        case parsed
        case noAmountFound
    }

    private var amount: Double {
        CurrencyParser.parseNumber(amountText) ?? 0
    }

    var body: some View {
        NavigationStack {
            Group {
                if let confirmation {
                    confirmationView(confirmation)
                } else {
                    content
                }
            }
            .background(AmbientBackground(tint: pickedCategory?.tint.color ?? .blue))
            .navigationTitle("From a screenshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if state == .parsed || state == .noAmountFound {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }
                            .buttonStyle(.glassProminent)
                            .disabled(amount <= 0)
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(.regularMaterial)
        .onAppear { if currencyCode.isEmpty { currencyCode = settings.homeCurrencyCode } }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: Theme.Metric.cardSpacing) {
                switch state {
                case .idle:
                    picker
                case .reading:
                    readingCard
                case .parsed, .noAmountFound:
                    if state == .noAmountFound { couldNotReadCard }
                    draftCard
                    categoryPicker
                    if !rawText.isEmpty { rawTextCard }
                }
            }
            .padding(Theme.Metric.gutter)
        }
    }

    private var picker: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 46))
                .foregroundStyle(.blue.gradient)

            Text("Pick a screenshot of a purchase notification and Tudget will read the amount off it.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            PhotosPicker(selection: $pickerItem, matching: .screenshots) {
                Label("Choose a screenshot", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Text("Any photo instead")
                    .font(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text("Faster still: screenshot the alert, hit Share, and pick Tudget — no need to open the app.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    private var readingCard: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading the screenshot…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .glassCard()
    }

    private var couldNotReadCard: some View {
        Label(
            "I couldn't find an amount in that image — type it in and it'll save just the same.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tintedGlassCard(.orange, radius: Theme.Metric.tightRadius)
    }

    private var draftCard: some View {
        VStack(spacing: 14) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 150)
                    .clipShape(.rect(cornerRadius: Theme.Metric.tightRadius))
            }

            VStack(spacing: 10) {
                LabeledContent("Merchant") {
                    TextField("Where", text: $merchant)
                        .multilineTextAlignment(.trailing)
                }
                Divider()
                LabeledContent("Amount") {
                    TextField("0", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }
                Divider()
                LabeledContent("Currency") {
                    Picker("", selection: $currencyCode) {
                        ForEach(Currency.pickerCodes(deviceCode: Currency.deviceCurrencyCode), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .labelsHidden()
                }
            }
            .font(.subheadline)
        }
        .glassCard()
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Category").font(.subheadline.weight(.semibold))
            GlassEffectContainer(spacing: 8) {
                FlowLayout(spacing: 8) {
                    ForEach(categories) { category in
                        let isSelected = pickedCategory?.uuid == category.uuid
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

    /// What Vision actually read. Hidden by default, but there when a parse
    /// looks wrong and you want to know why.
    private var rawTextCard: some View {
        DisclosureGroup(isExpanded: $showingRawText) {
            Text(rawText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        } label: {
            Label("What I read", systemImage: "text.viewfinder")
                .font(.subheadline.weight(.medium))
        }
        .glassCard(radius: Theme.Metric.tightRadius)
    }

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
    }

    // MARK: - Actions

    private func load(_ item: PhotosPickerItem) async {
        state = .reading
        guard let data = try? await item.loadTransferable(type: Data.self),
              let loaded = UIImage(data: data) else {
            state = .noAmountFound
            return
        }
        image = loaded

        let purchase = try? await VisionOCR.extractPurchase(
            from: loaded, defaultCurrency: settings.homeCurrencyCode
        )

        if let purchase {
            merchant = purchase.merchant ?? ""
            amountText = String(format: "%.2f", purchase.amount)
            currencyCode = purchase.currencyCode
            rawText = purchase.rawText
            // A merchant name often matches a category outright ("NETFLIX" ->
            // Subscriptions), which saves a tap when it's right and is easy to
            // undo when it isn't.
            if let name = CategoryMatcher.match(
                purchase.merchant ?? "", in: categories.map(\.name), threshold: 0.85
            ) {
                pickedCategory = categories.first { $0.name == name }
            }
            state = .parsed
        } else {
            rawText = ((try? await VisionOCR.recognizeText(in: loaded)) ?? []).joined(separator: "\n")
            state = .noAmountFound
        }
    }

    private func save() async {
        guard amount > 0 else { return }

        var receiptFilename: String?
        if let image, let data = image.jpegData(compressionQuality: 0.7) {
            receiptFilename = AppGroup.saveReceipt(data)
        }

        await Ledger.record(
            merchant: merchant.isEmpty ? "Unknown" : merchant,
            amount: amount,
            currencyCode: currencyCode,
            category: pickedCategory,
            receiptFilename: receiptFilename,
            source: .screenshot,
            context: context,
            settings: settings
        )

        await BudgetNotifier.shared.refreshAlerts(context: context, settings: settings)

        let period = settings.period()
        let summary = Ledger.summary(for: period, context: context, settings: settings)
        confirmation = pickedCategory.map {
            BudgetCalculator.confirmationLine(for: $0.uuid, summary: summary)
        } ?? "Logged. Tell me what it was when you get a moment."

        try? await Task.sleep(for: .milliseconds(1600))
        dismiss()
    }
}
