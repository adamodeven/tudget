import SwiftUI
import SwiftData
import UIKit

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
            .scrollDismissesKeyboard(.immediately)
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
                setupBullet("bolt.fill", "Type a line", "\"Trader Joe's $34 groceries\": merchant, amount, and category in one go.")
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

                Text("Take-home pay for one \(periodLength.label.lowercased()) cycle, after tax. Used to suggest limits, and you can change every one of them next.")
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
                    maxValue: takeHome,
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
    let maxValue: Double
    @Binding var value: Double

    @State private var isEditingText = false
    @State private var editText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(template.emoji) \(template.name)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if isEditingText {
                    TextField("0", text: $editText)
                        .keyboardType(.decimalPad)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .focused($isFocused)
                        .onSubmit { commitEdit() }
                } else {
                    Text(Currency.formatCompact(value, code: currencyCode))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .onTapGesture { beginEdit() }
                }
            }

            // Range is 0...takeHome: a single category can't sensibly exceed
            // the whole cycle's income, and a fixed range (rather than one
            // derived from the live value) keeps the thumb's position honest.
            PrecisionSlider(
                value: $value,
                range: 0...max(1, maxValue),
                step: 5,
                tint: template.tint.color,
                currencyCode: currencyCode
            )
        }
        .glassCard(radius: Theme.Metric.tightRadius)
        .onChange(of: isFocused) { _, focused in
            if !focused && isEditingText { commitEdit() }
        }
    }

    private func beginEdit() {
        editText = Currency.formatCompact(value, code: currencyCode)
            .filter { $0.isNumber || $0 == "." }
        isEditingText = true
        isFocused = true
    }

    private func commitEdit() {
        let parsed = CurrencyParser.parseNumber(editText) ?? value
        value = min(max(0, parsed), maxValue)
        isEditingText = false
        isFocused = false
    }
}

/// A slider that, like the scrubber in Photos/TV, rescales itself for
/// precise adjustment: hold your finger still (whether right on touch-down
/// or mid-drag) and after a beat the track zooms in around the current
/// value, trading range for precision until you lift.
private struct PrecisionSlider: View {

    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    let currencyCode: String

    private let trackHeight: CGFloat = 6
    private let thumbDiameter: CGFloat = 26
    private let hitDiameter: CGFloat = 44
    private let trackSpace = "PrecisionSlider.track"
    private let holdDuration: Duration = .milliseconds(450)
    private let zoomFactor: Double = 8

    @State private var isZoomed = false
    @State private var zoomRange: ClosedRange<Double>
    @State private var holdTask: Task<Void, Never>?

    init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, tint: Color, currencyCode: String) {
        self._value = value
        self.range = range
        self.step = step
        self.tint = tint
        self.currencyCode = currencyCode
        self._zoomRange = State(initialValue: range)
    }

    private var activeRange: ClosedRange<Double> { isZoomed ? zoomRange : range }

    var body: some View {
        VStack(spacing: 4) {
            if isZoomed {
                HStack {
                    Text(Currency.formatCompact(zoomRange.lowerBound, code: currencyCode))
                    Spacer()
                    Text("fine adjust")
                    Spacer()
                    Text(Currency.formatCompact(zoomRange.upperBound, code: currencyCode))
                }
                .font(.caption2)
                .foregroundStyle(tint)
                .transition(.opacity)
            }

            GeometryReader { geo in
                let width = geo.size.width
                let fraction = normalizedFraction(value, in: activeRange)
                let thumbX = width * fraction

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: trackHeight)

                    Capsule()
                        .fill(tint)
                        .frame(width: max(trackHeight, thumbX), height: trackHeight)

                    // The hit target is deliberately larger than the visible
                    // dot -- and it's the *only* thing that responds to
                    // touches, so tapping elsewhere on the track no longer
                    // yanks the value around.
                    Circle()
                        .fill(.white)
                        .shadow(radius: isZoomed ? 4 : 1)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .scaleEffect(isZoomed ? 1.15 : 1)
                        .frame(width: hitDiameter, height: hitDiameter)
                        .contentShape(Circle())
                        .offset(x: thumbX - hitDiameter / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named(trackSpace))
                                .onChanged { drag in handleDrag(drag, width: width) }
                                .onEnded { _ in handleDragEnd() }
                        )
                }
                .frame(height: max(thumbDiameter, hitDiameter))
                .coordinateSpace(name: trackSpace)
            }
            .frame(height: max(thumbDiameter, hitDiameter))
        }
        .animation(.easeInOut(duration: 0.25), value: isZoomed)
    }

    private func normalizedFraction(_ value: Double, in range: ClosedRange<Double>) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func handleDrag(_ drag: DragGesture.Value, width: CGFloat) {
        guard width > 0 else { return }
        let fraction = min(max(drag.location.x / width, 0), 1)
        let active = activeRange
        let raw = active.lowerBound + Double(fraction) * (active.upperBound - active.lowerBound)
        let stepped = (raw / step).rounded() * step
        value = min(max(stepped, range.lowerBound), range.upperBound)

        // Any movement pushes back the moment zoom engages; it only fires
        // once the finger has been still for `holdDuration`, so this works
        // whether you pause right on touch-down or mid-drag.
        holdTask?.cancel()
        if !isZoomed {
            holdTask = Task {
                try? await Task.sleep(for: holdDuration)
                guard !Task.isCancelled else { return }
                await MainActor.run { enterZoom() }
            }
        }
    }

    private func handleDragEnd() {
        holdTask?.cancel()
        holdTask = nil
        if isZoomed {
            isZoomed = false
            zoomRange = range
        }
    }

    private func enterZoom() {
        guard !isZoomed else { return }
        let fullSpan = range.upperBound - range.lowerBound
        guard fullSpan > 0 else { return }
        let zoomSpan = min(fullSpan, max(fullSpan / zoomFactor, step * 4))

        // Anchor the zoomed window so the value's fraction across it matches
        // its fraction across the full range -- the point under the finger
        // doesn't jump, only the scale around it changes.
        let fraction = Double(normalizedFraction(value, in: range))
        var lower = value - fraction * zoomSpan
        var upper = lower + zoomSpan
        if lower < range.lowerBound {
            upper += range.lowerBound - lower
            lower = range.lowerBound
        }
        if upper > range.upperBound {
            lower -= upper - range.upperBound
            upper = range.upperBound
        }

        zoomRange = lower...upper
        isZoomed = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
