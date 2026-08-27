import SwiftUI
import SwiftData

/// First-run setup: currency, cycle, pay, limits.
///
/// This is `setup_budget.py` rebuilt as a screen -- same modified 50/30/20
/// suggestion, same "adjust anything you like before committing", except the
/// numbers are per *period* rather than per month.
struct BudgetSetupView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context

    @Query private var existingCategories: [BudgetCategory]

    @State private var step: Step = .welcome
    @State private var currencyCode = ""
    @State private var periodLength: BudgetPeriodLength = .biweekly
    @State private var anchor = BudgetPeriodCalculator.mondayOnOrBefore(Date())
    @State private var takeHomeText = ""
    @State private var limits: [String: Double] = [:]

    enum Step: Int, CaseIterable {
        case welcome, cycle, pay, limits
    }

    private var takeHome: Double {
        CurrencyParser.parseNumber(takeHomeText) ?? 0
    }

    private var totalLimit: Double {
        limits.values.reduce(0, +)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metric.cardSpacing) {
                    switch step {
                    case .welcome: welcomeStep
                    case .cycle: cycleStep
                    case .pay: payStep
                    case .limits: limitsStep
                    }
                }
                .padding(Theme.Metric.gutter)
                .padding(.bottom, 40)
            }
            .background(AmbientBackground(tint: .blue))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .welcome {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back") { withAnimation(.smooth) { back() } }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(step == .limits ? "Done" : "Next") {
                        withAnimation(.smooth) { advance() }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!canAdvance)
                }
            }
        }
        .onAppear {
            if currencyCode.isEmpty { currencyCode = settings.homeCurrencyCode }
        }
    }

    private var title: String {
        switch step {
        case .welcome: return "Welcome"
        case .cycle: return "Your cycle"
        case .pay: return "Take-home"
        case .limits: return "Your budget"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .welcome, .cycle: return true
        case .pay: return takeHome > 0
        case .limits: return totalLimit > 0
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 54))
                .foregroundStyle(.blue.gradient)

            Text("Tudget")
                .font(Theme.title)

            Text("Log a purchase in two taps. Know whether you can afford the next one.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                setupBullet("bolt.fill", "Type a line", "\"Trader Joe's $34 groceries\" — merchant, amount, and category in one go.")
                setupBullet("square.and.arrow.up", "Share a screenshot", "Screenshot a bank alert, share it to Tudget, and it reads the amount.")
                setupBullet("chart.xyaxis.line", "See your pace", "Know the day you'd run out at the rate you're going.")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    private func setupBullet(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var cycleStep: some View {
        VStack(spacing: Theme.Metric.cardSpacing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Currency").font(.subheadline.weight(.semibold))
                Picker("Currency", selection: $currencyCode) {
                    ForEach(Currency.pickerCodes(deviceCode: Currency.deviceCurrencyCode), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .pickerStyle(.menu)
                Text("Budgets are tracked in this. Purchases in any other currency are converted when you log them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("Budget resets").font(.subheadline.weight(.semibold))
                Picker("Length", selection: $periodLength) {
                    ForEach(BudgetPeriodLength.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if periodLength != .monthly {
                    DatePicker(
                        "Starting",
                        selection: $anchor,
                        displayedComponents: .date
                    )
                    .onChange(of: anchor) { _, newValue in
                        // Cycles are far easier to hold in your head when they
                        // start when the week does.
                        anchor = BudgetPeriodCalculator.mondayOnOrBefore(newValue)
                    }

                    Text("Snapped to the Monday on or before the date you pick. Every cycle runs from there.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }

    private var payStep: some View {
        VStack(spacing: Theme.Metric.cardSpacing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("What lands in your account each cycle?")
                    .font(.subheadline.weight(.semibold))

                TextField("0", text: $takeHomeText)
                    .keyboardType(.decimalPad)
                    .font(Theme.title)

                Text("Take-home pay for one \(periodLength.label.lowercased()) cycle, after tax. Used to suggest limits — you can change every one of them next.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()

            if takeHome > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A 50/30/20 starting point")
                        .font(.subheadline.weight(.semibold))
                    ForEach(BudgetCategory.templates) { template in
                        StatRow(
                            label: "\(template.emoji) \(template.name)",
                            value: Currency.formatCompact(
                                takeHome * template.fractionOfTakeHome, code: currencyCode
                            )
                        )
                    }
                    Divider()
                    StatRow(
                        label: "💰 Savings (not tracked)",
                        value: Currency.formatCompact(
                            takeHome * BudgetCategory.savingsFraction, code: currencyCode
                        ),
                        valueColor: .green
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
            }
        }
    }

    private var limitsStep: some View {
        VStack(spacing: Theme.Metric.cardSpacing) {
            VStack(spacing: 4) {
                Text(Currency.format(totalLimit, code: currencyCode))
                    .font(Theme.title)
                    .contentTransition(.numericText())
                Text("to spend each cycle")
                    .font(.footnote).foregroundStyle(.secondary)
                if takeHome > 0 {
                    Text("\(Currency.formatCompact(max(0, takeHome - totalLimit), code: currencyCode)) left over")
                        .font(.caption)
                        .foregroundStyle(takeHome - totalLimit < 0 ? .red : .green)
                }
            }
            .frame(maxWidth: .infinity)
            .glassCard()

            ForEach(BudgetCategory.templates) { template in
                LimitEditor(
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

    // MARK: - Navigation

    private func back() {
        guard let index = Step.allCases.firstIndex(of: step), index > 0 else { return }
        step = Step.allCases[index - 1]
    }

    private func advance() {
        switch step {
        case .welcome:
            step = .cycle
        case .cycle:
            step = .pay
        case .pay:
            limits = BudgetCategory.suggestedLimits(takeHomePerPeriod: takeHome)
            step = .limits
        case .limits:
            finish()
        }
    }

    private func finish() {
        settings.homeCurrencyCode = currencyCode
        settings.periodLength = periodLength
        settings.periodAnchor = anchor
        settings.takeHomePerPeriod = takeHome

        let categories = BudgetCategory.templates.enumerated().map { index, template in
            BudgetCategory(
                name: template.name,
                periodLimit: limits[template.name] ?? 0,
                emoji: template.emoji,
                tint: template.tint,
                sortOrder: index
            )
        }
        Ledger.replaceCategories(with: categories, context: context)

        settings.hasCompletedSetup = true

        Task { await BudgetNotifier.shared.requestAuthorization() }
    }
}

private struct LimitEditor: View {

    let template: BudgetCategory.Template
    let currencyCode: String
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(template.emoji) \(template.name)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(Currency.formatCompact(value, code: currencyCode))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            Slider(value: $value, in: 0...max(50, value * 2.5), step: 5)
                .tint(template.tint.color)
        }
        .glassCard(radius: Theme.Metric.tightRadius)
    }
}
