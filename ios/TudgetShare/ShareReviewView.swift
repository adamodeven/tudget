import SwiftUI
import SwiftData

/// The share extension's whole UI: what was read, and which category it goes in.
///
/// Modelled on the old SMS exchange — here's what I think you spent, tell me
/// what it was — because that flow only ever needed one decision from you, and
/// tapping a category is faster than filling in a form.
struct ShareReviewView: View {

    let image: UIImage?
    let onFinish: () -> Void
    let onCancel: () -> Void

    @State private var settings = AppSettings.shared
    @State private var context = ModelContext(LedgerStore.shared)

    @State private var categories: [BudgetCategory] = []
    @State private var phase: Phase = .reading
    @State private var merchant = ""
    @State private var amountText = ""
    @State private var currencyCode = "USD"
    @State private var pickedCategory: BudgetCategory?
    @State private var confirmation: String?

    private enum Phase: Equatable {
        case reading
        case ready
        case noAmount
        case saving
    }

    private var amount: Double { CurrencyParser.parseNumber(amountText) ?? 0 }

    var body: some View {
        NavigationStack {
            Group {
                if let confirmation {
                    done(confirmation)
                } else if phase == .reading {
                    reading
                } else {
                    form
                }
            }
            .background(backdrop)
            .navigationTitle("Log a purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                if phase == .ready || phase == .noAmount {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }
                            .disabled(amount <= 0)
                            .buttonStyle(.glassProminent)
                    }
                }
            }
        }
        .task { await load() }
    }

    private var backdrop: some View {
        ZStack {
            Color(.systemBackground)
            EllipticalGradient(
                colors: [(pickedCategory?.tint.color ?? .blue).opacity(0.28), .clear],
                center: .init(x: 0.2, y: 0.05),
                startRadiusFraction: 0,
                endRadiusFraction: 0.8
            )
        }
        .ignoresSafeArea()
    }

    private var reading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading the screenshot…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: 14) {
                if phase == .noAmount {
                    Label(
                        "I couldn't read an amount off that — type it in and it'll save just the same.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassEffect(.regular.tint(.orange.opacity(0.2)), in: .rect(cornerRadius: 18))
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
                }
                .font(.subheadline)
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))

                VStack(alignment: .leading, spacing: 10) {
                    Text("Category")
                        .font(.subheadline.weight(.semibold))

                    GlassEffectContainer(spacing: 10) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 104), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(categories) { category in
                                Button {
                                    withAnimation(.smooth) {
                                        pickedCategory =
                                            pickedCategory?.uuid == category.uuid ? nil : category
                                    }
                                } label: {
                                    VStack(spacing: 3) {
                                        Text(category.emoji.isEmpty ? "•" : category.emoji)
                                        Text(category.name)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .glassEffect(
                                        .regular.tint(
                                            category.tint.color.opacity(
                                                pickedCategory?.uuid == category.uuid ? 0.55 : 0.22
                                            )
                                        ).interactive(),
                                        in: .rect(cornerRadius: 16)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Text("Leave it blank and it'll wait for you in the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 130)
                        .clipShape(.rect(cornerRadius: 16))
                        .opacity(0.85)
                }
            }
            .padding(16)
        }
    }

    private func done(_ line: String) -> some View {
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

    // MARK: - Actions

    @MainActor
    private func load() async {
        currencyCode = settings.homeCurrencyCode
        categories = Ledger.categories(in: context)

        guard let image else {
            phase = .noAmount
            return
        }

        let purchase = try? await VisionOCR.extractPurchase(
            from: image, defaultCurrency: settings.homeCurrencyCode
        )

        if let purchase {
            merchant = purchase.merchant ?? ""
            amountText = String(format: "%.2f", purchase.amount)
            currencyCode = purchase.currencyCode
            if let name = CategoryMatcher.match(
                purchase.merchant ?? "", in: categories.map(\.name), threshold: 0.85
            ) {
                pickedCategory = categories.first { $0.name == name }
            }
            phase = .ready
        } else {
            phase = .noAmount
        }
    }

    @MainActor
    private func save() async {
        guard amount > 0 else { return }
        phase = .saving

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
            source: .shareExtension,
            context: context,
            settings: settings
        )

        let period = settings.period()
        let summary = Ledger.summary(for: period, context: context, settings: settings)
        confirmation = pickedCategory.map {
            BudgetCalculator.confirmationLine(for: $0.uuid, summary: summary)
        } ?? "Logged. Tell me what it was when you open Tudget."

        try? await Task.sleep(for: .milliseconds(1500))
        onFinish()
    }
}
