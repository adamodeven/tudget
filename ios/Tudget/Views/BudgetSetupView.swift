import SwiftUI
import SwiftData

/// First-run setup: home currency, take-home pay, and a starting budget.
///
/// Same modified 50/30/20 split `setup_budget.py` suggests, but the limits are
/// editable inline before anything is written, so the suggestion is a starting
/// point rather than a decision made for you.
struct BudgetSetupView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var existingCategories: [BudgetCategory]

    private enum Step: Int, CaseIterable {
        case currency, income, review
    }

    @State private var step: Step = .currency
    @State private var currencyCode = ""
    @State private var takeHomeText = ""
    @State private var limits: [String: Double] = [:]

    private var takeHomePay: Double? {
        CurrencyParser.parseNumber(takeHomeText)
    }

    private var totalLimit: Double {
        limits.values.reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(
                    value: Double(step.rawValue + 1), total: Double(Step.allCases.count)
                )
                .padding(.horizontal)

                Group {
                    switch step {
                    case .currency: currencyStep
                    case .income: incomeStep
                    case .review: reviewStep
                    }
                }
                .frame(maxHeight: .infinity)

                footer
            }
            .navigationTitle("Set up Tudget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { finish(createCategories: false) }
                }
            }
            .onAppear {
                if currencyCode.isEmpty {
                    currencyCode = settings.homeCurrency
                }
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Steps

    private var currencyStep: some View {
        VStack(spacing: 20) {
            SetupHeader(
                icon: "globe",
                title: "What's your home currency?",
                message: "Budgets and totals are tracked in this currency. You can still log purchases in any other currency — Tudget converts them."
            )

            Picker("Home currency", selection: $currencyCode) {
                ForEach(Currency.pickerCodes(deviceCode: Currency.deviceCurrencyCode), id: \.self) {
                    Text($0).tag($0)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 160)

            Spacer()
        }
        .padding()
    }

    private var incomeStep: some View {
        VStack(spacing: 20) {
            SetupHeader(
                icon: "banknote",
                title: "Monthly take-home pay?",
                message: "Used once, to suggest a starting budget. You can edit every number on the next screen."
            )

            HStack {
                Text(Currency.displaySymbol[currencyCode] ?? currencyCode)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("4500", text: $takeHomeText)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

            Spacer()
        }
        .padding()
    }

    private var reviewStep: some View {
        VStack(spacing: 0) {
            SetupHeader(
                icon: "chart.pie",
                title: "Your starting budget",
                message: "Tap any amount to change it."
            )
            .padding()

            List {
                ForEach(BudgetCategory.Template.Group.allGroups, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(BudgetCategory.templates.filter { $0.group == group }, id: \.name) { template in
                            LimitRow(
                                template: template,
                                currencyCode: currencyCode,
                                value: Binding(
                                    get: { limits[template.name] ?? 0 },
                                    set: { limits[template.name] = $0 }
                                )
                            )
                        }
                    }
                }

                Section {
                    LabeledContent("Total budget") {
                        Text(Currency.formatCompact(totalLimit, code: currencyCode))
                            .fontWeight(.semibold)
                    }
                    if let takeHomePay {
                        LabeledContent("Left for savings") {
                            Text(Currency.formatCompact(max(0, takeHomePay - totalLimit), code: currencyCode))
                                .foregroundStyle(Color.tudgetAccent)
                        }
                    }
                } footer: {
                    Text("Savings isn't a spending category — it's just what's left after these budgets.")
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button(action: advance) {
                Text(step == .review ? "Start tracking" : "Continue")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canAdvance ? Color.tudgetAccent : Color.secondary.opacity(0.3),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .disabled(!canAdvance)

            if step != .currency {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .currency
                }
                .font(.footnote)
            }
        }
        .padding()
    }

    private var canAdvance: Bool {
        switch step {
        case .currency: return !currencyCode.isEmpty
        case .income: return (takeHomePay ?? 0) > 0
        case .review: return true
        }
    }

    // MARK: - Flow

    private func advance() {
        switch step {
        case .currency:
            step = .income
        case .income:
            if let takeHomePay {
                limits = BudgetCategory.suggestedLimits(takeHomePay: takeHomePay)
            }
            step = .review
        case .review:
            finish(createCategories: true)
        }
    }

    private func finish(createCategories: Bool) {
        settings.homeCurrency = currencyCode.isEmpty ? settings.homeCurrency : currencyCode

        // Only seed categories on a genuinely fresh install; re-running setup
        // must never duplicate a budget the user has already tuned.
        if createCategories && existingCategories.isEmpty {
            for (index, template) in BudgetCategory.templates.enumerated() {
                context.insert(
                    BudgetCategory(
                        name: template.name,
                        monthlyLimit: limits[template.name] ?? 0,
                        emoji: template.emoji,
                        sortOrder: index
                    )
                )
            }
            try? context.save()
            LedgerActions.publishCategorySnapshot(from: context)
        }

        settings.hasCompletedSetup = true
        dismiss()
    }
}

// MARK: - Pieces

private struct SetupHeader: View {

    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(Color.tudgetAccent)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
    }
}

private struct LimitRow: View {

    let template: BudgetCategory.Template
    let currencyCode: String
    @Binding var value: Double

    @State private var text = ""

    var body: some View {
        HStack {
            Text("\(template.emoji) \(template.name)")
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .onChange(of: text) { _, newValue in
                    value = CurrencyParser.parseNumber(newValue) ?? 0
                }
            Text(currencyCode)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if text.isEmpty { text = String(format: "%.0f", value) }
        }
    }
}

extension BudgetCategory.Template.Group {
    static var allGroups: [BudgetCategory.Template.Group] { [.needs, .wants] }
}
