import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context

    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showingResetConfirmation = false
    @State private var editingCategory: BudgetCategory?
    @State private var showingNewCategory = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metric.cardSpacing) {
                    categoriesCard
                    cycleCard
                    alertsCard(settings: settings)
                    aboutCard
                    resetButton
                }
                .padding(.horizontal, Theme.Metric.gutter)
                .padding(.bottom, 90)
            }
            .background(AmbientBackground(tint: .blue))
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editingCategory) { CategoryEditor(category: $0) }
            .sheet(isPresented: $showingNewCategory) { CategoryEditor(category: nil) }
            .task { notificationStatus = await BudgetNotifier.shared.authorizationStatus() }
            .confirmationDialog(
                "Start over?",
                isPresented: $showingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) { reset() }
            } message: {
                Text("Deletes every purchase, category, and setting on this device.")
            }
        }
    }

    // MARK: - Categories

    private var categoriesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Categories").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showingNewCategory = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glass)
            }

            Text("Limits are per \(settings.periodLength.label.lowercased()) cycle, in \(settings.homeCurrencyCode).")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(categories) { category in
                Button {
                    editingCategory = category
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(category.tint.color)
                            .frame(width: 10, height: 10)
                        Text(category.displayName)
                            .font(.subheadline)
                        Spacer()
                        Text(Currency.formatCompact(category.periodLimit, code: settings.homeCurrencyCode))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                if category.id != categories.last?.id { Divider() }
            }

            Divider()
            HStack {
                Text("Total per cycle").font(.subheadline.weight(.semibold))
                Spacer()
                Text(Currency.format(
                    categories.reduce(0) { $0 + $1.periodLimit },
                    code: settings.homeCurrencyCode
                ))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Cycle

    private var cycleCard: some View {
        @Bindable var settings = settings

        return VStack(alignment: .leading, spacing: 12) {
            Text("Budget cycle").font(.subheadline.weight(.semibold))

            Picker("Length", selection: $settings.periodLength) {
                ForEach(BudgetPeriodLength.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if settings.periodLength != .monthly {
                DatePicker(
                    "Starts",
                    selection: $settings.periodAnchor,
                    displayedComponents: .date
                )
                .font(.subheadline)
                .onChange(of: settings.periodAnchor) { _, newValue in
                    let snapped = BudgetPeriodCalculator.mondayOnOrBefore(newValue)
                    if snapped != newValue { settings.periodAnchor = snapped }
                }
            }

            Divider()

            StatRow(label: "This cycle", value: settings.period().formattedRange())
            StatRow(label: "Ends", value: settings.period().remainingDescription())

            Divider()

            Picker("Currency", selection: $settings.homeCurrencyCode) {
                ForEach(Currency.pickerCodes(deviceCode: Currency.deviceCurrencyCode), id: \.self) {
                    Text($0).tag($0)
                }
            }
            .font(.subheadline)

            Text("Changing this doesn't reconvert past purchases. Each one keeps the rate it was logged at.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - Alerts

    private func alertsCard(settings: AppSettings) -> some View {
        @Bindable var settings = settings

        return VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $settings.alertsEnabled) {
                Text("Budget alerts").font(.subheadline.weight(.semibold))
            }

            if settings.alertsEnabled {
                if notificationStatus == .denied {
                    Label(
                        "Notifications are off for Tudget in iOS Settings.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else if notificationStatus == .notDetermined {
                    Button("Allow notifications") {
                        Task {
                            await BudgetNotifier.shared.requestAuthorization()
                            notificationStatus = await BudgetNotifier.shared.authorizationStatus()
                        }
                    }
                    .buttonStyle(.glass)
                    .font(.subheadline)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Warn me at").font(.subheadline)
                        Spacer()
                        Text("\(Int(settings.warnThreshold * 100))%")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    Slider(value: $settings.warnThreshold, in: 0.5...0.95, step: 0.05)
                }

                Text("One alert per category per cycle, plus one if your overall pace would run you out early.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: - About

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture shortcuts").font(.subheadline.weight(.semibold))

            aboutRow("square.and.arrow.up", "Share sheet",
                     "Screenshot a bank alert → Share → Tudget.")
            aboutRow("switch.2", "Control Centre",
                     "Add the Tudget control to log a purchase from anywhere.")
            aboutRow("rectangle.stack", "Widgets",
                     "Home and Lock Screen widgets show what's left and open straight into entry.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func aboutRow(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.blue)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var resetButton: some View {
        Button(role: .destructive) {
            showingResetConfirmation = true
        } label: {
            Label("Start over", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .tint(.red)
    }

    private func reset() {
        for transaction in Ledger.allTransactions(in: context) {
            context.delete(transaction)
        }
        for category in categories {
            context.delete(category)
        }
        Ledger.save(context)
        settings.reset()
    }
}

/// Add or edit one category.
private struct CategoryEditor: View {

    let category: BudgetCategory?

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \BudgetCategory.sortOrder) private var categories: [BudgetCategory]

    @State private var name = ""
    @State private var emoji = ""
    @State private var limitText = ""
    @State private var tint: CategoryTint = .blue

    private var limit: Double { CurrencyParser.parseNumber(limitText) ?? 0 }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metric.cardSpacing) {
                    VStack(spacing: 10) {
                        LabeledContent("Name") {
                            TextField("Groceries", text: $name)
                                .multilineTextAlignment(.trailing)
                        }
                        Divider()
                        LabeledContent("Emoji") {
                            TextField("🍔", text: $emoji)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: emoji) { _, new in
                                    // One glyph is all the tile has room for.
                                    if new.count > 1 { emoji = String(new.suffix(1)) }
                                }
                        }
                        Divider()
                        LabeledContent("Limit per cycle") {
                            TextField("0", text: $limitText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                    }
                    .font(.subheadline)
                    .glassCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Colour").font(.subheadline.weight(.semibold))
                        Text("Every colour here is checked for colourblind separation, so the set is deliberately small.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        GlassEffectContainer(spacing: 8) {
                            FlowLayout(spacing: 8) {
                                ForEach(CategoryTint.allCases) { option in
                                    Button {
                                        tint = option
                                    } label: {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(option.color)
                                                .frame(width: 12, height: 12)
                                            Text(option.label).font(.caption)
                                        }
                                        .glassChip(tint: option.color, selected: tint == option)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard()

                    if category != nil {
                        Button(role: .destructive) {
                            if let category { Ledger.delete(category, context: context) }
                            dismiss()
                        } label: {
                            Label("Delete category", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .tint(.red)

                        Text("Purchases in this category are kept. They just become uncategorized.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(Theme.Metric.gutter)
            }
            .background(AmbientBackground(tint: tint.color))
            .navigationTitle(category == nil ? "New category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .buttonStyle(.glassProminent)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(.regularMaterial)
        .onAppear(perform: load)
    }

    private func load() {
        guard let category else { return }
        name = category.name
        emoji = category.emoji
        limitText = String(format: "%.0f", category.periodLimit)
        tint = category.tint
    }

    private func save() {
        if let category {
            category.name = name
            category.emoji = emoji
            category.periodLimit = limit
            category.tint = tint
        } else {
            let new = BudgetCategory(
                name: name,
                periodLimit: limit,
                emoji: emoji,
                tint: tint,
                sortOrder: (categories.map(\.sortOrder).max() ?? 0) + 1
            )
            context.insert(new)
        }
        Ledger.save(context)
        dismiss()
    }
}

extension BudgetCategory: Identifiable {
    var id: UUID { uuid }
}
