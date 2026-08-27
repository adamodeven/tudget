import SwiftUI

/// The share extension's whole UI: read the screenshot, show what was found,
/// let the user fix it and pick a category, then queue it for the app.
struct ShareReviewView: View {

    let loadAttachment: () async -> ShareViewController.Attachment
    let onComplete: () -> Void
    let onCancel: () -> Void

    private enum Stage {
        case reading
        case review
        case saved
        case failed(String)
    }

    @State private var stage: Stage = .reading
    @State private var merchant = ""
    @State private var amountText = ""
    @State private var currencyCode = AppSettings.homeCurrencyForExtension
    @State private var selectedCategoryID: UUID?
    @State private var image: UIImage?
    @State private var imageData: Data?
    @State private var rawText: String?

    private let categories = SharedStore.readCategorySnapshot()

    private var amount: Double? { CurrencyParser.parseNumber(amountText) }
    private var canSave: Bool {
        (amount ?? 0) > 0 && !merchant.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .reading: readingView
                case .review: reviewForm
                case .saved: savedView
                case .failed(let message): failedView(message)
                }
            }
            .navigationTitle("Add to Tudget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .review = stage {
                        Button("Save", action: save).disabled(!canSave)
                    }
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Stages

    private var readingView: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Reading…").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewForm: some View {
        Form {
            Section("Purchase") {
                TextField("Merchant", text: $merchant)
                    .textInputAutocapitalization(.words)
                HStack {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                    Divider()
                    Picker("", selection: $currencyCode) {
                        ForEach(Currency.pickerCodes(deviceCode: Currency.deviceCurrencyCode), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .labelsHidden()
                }
            }

            if !categories.isEmpty {
                Section("Category") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(categories) { category in
                                Button {
                                    selectedCategoryID =
                                        selectedCategoryID == category.id ? nil : category.id
                                } label: {
                                    Text(category.displayName)
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(
                                            selectedCategoryID == category.id
                                                ? Color.accentColor
                                                : Color.secondary.opacity(0.15),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(
                                            selectedCategoryID == category.id ? .white : .primary
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if let image {
                Section("Screenshot") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var savedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Saved to Tudget").font(.headline)
            Text("It'll appear next time you open the app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Close", action: onCancel)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Work

    private func load() async {
        let attachment = await loadAttachment()
        let home = AppSettings.homeCurrencyForExtension

        switch attachment {
        case .image(let uiImage, let data):
            image = uiImage
            imageData = data

            // `try?` flattens the optional return, so this is a single
            // optional: nil means either OCR failed or it found no amount.
            if let parsed = try? await VisionOCR.extractPurchase(
                from: uiImage, defaultCurrency: home
            ) {
                apply(merchant: parsed.merchant, amount: parsed.amount,
                      currency: parsed.currencyCode, rawText: parsed.rawText)
            } else {
                rawText = (try? await VisionOCR.recognizeText(in: uiImage))?
                    .joined(separator: " ")
            }
            stage = .review

        case .text(let text):
            if let parsed = PurchaseTextParser.parseNotification(text, defaultCurrency: home) {
                apply(merchant: parsed.merchant, amount: parsed.amount,
                      currency: parsed.currencyCode, rawText: parsed.rawText)
            } else {
                rawText = text
            }
            stage = .review

        case .empty:
            stage = .failed("Nothing to read here — share a screenshot or some text.")
        }
    }

    private func apply(merchant: String?, amount: Double, currency: String, rawText: String?) {
        self.merchant = merchant ?? ""
        self.amountText = String(
            format: "%.\(Currency.decimalPlaces(for: currency))f", amount
        )
        self.currencyCode = currency
        self.rawText = rawText

        // Guess a category from the merchant, same as the in-app flow.
        if let merchant,
           let matched = CategoryMatcher.match(
               merchant, in: categories.map(\.name), threshold: 0.9
           ) {
            selectedCategoryID = categories.first { $0.name == matched }?.id
        }
    }

    private func save() {
        guard let amount else { return }

        var receiptFilename: String?
        if let imageData {
            receiptFilename = try? SharedStore.saveReceipt(imageData)
        }

        let purchase = PendingPurchase(
            merchant: merchant.trimmingCharacters(in: .whitespaces),
            amount: amount,
            currencyCode: currencyCode,
            categoryID: selectedCategoryID,
            note: nil,
            receiptFilename: receiptFilename,
            rawText: rawText
        )

        do {
            try SharedStore.enqueue(purchase)
            stage = .saved
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                onComplete()
            }
        } catch {
            stage = .failed("Couldn't save: \(error.localizedDescription)")
        }
    }
}
