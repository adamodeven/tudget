import SwiftUI
import SwiftData
import UIKit
import PhotosUI

/// Logging a purchase from a screenshot of a bank or payment-app notification.
///
/// Pick the screenshot, Vision reads it on device, and whatever it found is
/// shown as an editable draft rather than saved blind -- OCR on a lock-screen
/// banner is good but not good enough to trust silently with your ledger.
struct ScreenshotImportView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\BudgetCategory.sortOrder), SortDescriptor(\BudgetCategory.name)])
    private var categories: [BudgetCategory]

    private enum Stage {
        case picking
        case reading
        case review
        case unreadable
    }

    @State private var stage: Stage = .picking
    @State private var photoItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var image: UIImage?
    @State private var rawText: String?

    @State private var merchant = ""
    @State private var amountText = ""
    @State private var currencyCode = ""
    @State private var selectedCategory: BudgetCategory?
    @State private var isSaving = false

    private var amount: Double? { CurrencyParser.parseNumber(amountText) }
    private var canSave: Bool {
        (amount ?? 0) > 0 && !merchant.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .picking: pickingView
                case .reading: readingView
                case .review, .unreadable: reviewView
                }
            }
            .navigationTitle("From screenshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if currencyCode.isEmpty { currencyCode = settings.homeCurrency }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
        }
    }

    // MARK: - Stages

    private var pickingView: some View {
        VStack(spacing: 24) {
            EmptyStateView(
                systemImage: "camera.viewfinder",
                title: "Pick a notification screenshot",
                message: "Screenshot the purchase alert from your bank or payment app, and Tudget will read the amount and merchant off it."
            )

            PhotosPicker(selection: $photoItem, matching: .screenshots) {
                Label("Choose screenshot", systemImage: "photo.on.rectangle")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.tudgetAccent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Text("Choose any photo instead")
                    .font(.footnote)
            }

            Spacer()
        }
        .padding()
    }

    private var readingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Reading the screenshot…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var reviewView: some View {
        Form {
            if stage == .unreadable {
                Section {
                    Label(
                        "Couldn't find an amount in that screenshot — fill it in below.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.tudgetWarning)
                }
            }

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
            }

            Section("Category") {
                CategoryPicker(categories: categories, selection: $selectedCategory)
            }

            if let image {
                Section("Screenshot") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            if let rawText, !rawText.isEmpty {
                Section("What Tudget read") {
                    Text(rawText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
    }

    // MARK: - Work

    private func load(_ item: PhotosPickerItem) async {
        stage = .reading

        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data) else {
            stage = .unreadable
            return
        }

        imageData = data
        image = uiImage

        let parsed = try? await VisionOCR.extractPurchase(
            from: uiImage, defaultCurrency: settings.homeCurrency
        )

        if let parsed {
            merchant = parsed.merchant ?? ""
            amountText = String(
                format: "%.\(Currency.decimalPlaces(for: parsed.currencyCode))f", parsed.amount
            )
            currencyCode = parsed.currencyCode
            rawText = parsed.rawText
            // Guess a category from the merchant name -- "STARBUCKS" hits the
            // Food aliases. Wrong guesses are one tap to fix.
            if let merchantName = parsed.merchant,
               let matched = CategoryMatcher.match(
                   merchantName, in: categories.map(\.name), threshold: 0.9
               ) {
                selectedCategory = categories.first { $0.name == matched }
            }
            stage = .review
        } else {
            rawText = (try? await VisionOCR.recognizeText(in: uiImage))?
                .joined(separator: " ")
            stage = .unreadable
        }
    }

    private func save() async {
        guard let amount else { return }
        isSaving = true

        await LedgerActions.addTransaction(
            in: context,
            merchant: merchant.trimmingCharacters(in: .whitespaces),
            amount: amount,
            currencyCode: currencyCode,
            category: selectedCategory,
            receiptData: imageData,
            note: nil,
            source: .screenshot,
            settings: settings
        )

        isSaving = false
        dismiss()
    }
}
