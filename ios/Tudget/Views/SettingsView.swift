import SwiftUI
import SwiftData

struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context

    @Query private var transactions: [Transaction]
    @Query(sort: [SortDescriptor(\BudgetCategory.sortOrder), SortDescriptor(\BudgetCategory.name)])
    private var categories: [BudgetCategory]

    @State private var isRecalculating = false
    @State private var syncStatus: String?
    @State private var isSyncing = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    Picker("Home currency", selection: $settings.homeCurrency) {
                        ForEach(Currency.pickerCodes(deviceCode: Currency.deviceCurrencyCode), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .onChange(of: settings.homeCurrency) { _, _ in
                        Task { await recalculate() }
                    }

                    if isRecalculating {
                        HStack {
                            ProgressView()
                            Text("Reconverting past purchases…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Currency")
                } footer: {
                    Text("Budgets and totals use this currency. Changing it reconverts every past purchase at today's rate.")
                }

                Section("Budget") {
                    NavigationLink {
                        CategoriesView()
                    } label: {
                        LabeledContent("Categories", value: "\(categories.count)")
                    }

                    LabeledContent(
                        "Monthly budget",
                        value: Currency.formatCompact(
                            categories.reduce(0) { $0 + $1.monthlyLimit },
                            code: settings.homeCurrency
                        )
                    )
                }

                syncSection

                Section("Data") {
                    LabeledContent("Purchases logged", value: "\(transactions.count)")
                    ShareLink(
                        item: csvFile(),
                        preview: SharePreview("Tudget export")
                    ) {
                        Label("Export CSV", systemImage: "square.and.arrow.up")
                    }
                }

                Section {
                    Button("Run setup again") {
                        settings.hasCompletedSetup = false
                    }
                } footer: {
                    Text("Tudget \(appVersion). Purchases are stored on this device; syncing is optional.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Sync

    @ViewBuilder
    private var syncSection: some View {
        @Bindable var settings = settings

        Section {
            Toggle("Sync to my server", isOn: $settings.syncEnabled)

            if settings.syncEnabled {
                TextField("https://your-server.ngrok-free.app", text: $settings.serverBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField("API token", text: $settings.serverToken)

                Button {
                    Task { await syncNow() }
                } label: {
                    HStack {
                        Text("Sync now")
                        Spacer()
                        if isSyncing { ProgressView() }
                    }
                }
                .disabled(!settings.isSyncConfigured || isSyncing)

                if let syncStatus {
                    Text(syncStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Sync (optional)")
        } footer: {
            Text("Pushes purchases to the self-hosted Tudget server so the Notion dashboard, bank-email parsing, and Plaid reconciliation keep working. Leave off to use Tudget entirely on-device.")
        }
    }

    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }

        let result = await SyncService.syncPending(in: context, settings: settings)
        switch result {
        case .success(let count):
            syncStatus = count == 0
                ? "Everything already synced."
                : "Synced \(count) purchase\(count == 1 ? "" : "s")."
        case .failure(let error):
            syncStatus = "Sync failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func recalculate() async {
        isRecalculating = true
        await LedgerActions.recalculateHomeAmounts(in: context, settings: settings)
        isRecalculating = false
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// Writes a CSV of every purchase to a temp file for ShareLink.
    private func csvFile() -> URL {
        let header = "Date,Merchant,Amount,Currency,Amount (\(settings.homeCurrency)),Category,Source,Note\n"
        let rows = transactions
            .sorted { $0.timestamp > $1.timestamp }
            .map { transaction in
                [
                    ISO8601DateFormatter().string(from: transaction.timestamp),
                    csvEscape(transaction.merchant),
                    String(format: "%.2f", transaction.amount),
                    transaction.currencyCode,
                    String(format: "%.2f", transaction.amountInHomeCurrency),
                    csvEscape(transaction.category?.name ?? ""),
                    transaction.source.rawValue,
                    csvEscape(transaction.note ?? ""),
                ].joined(separator: ",")
            }
            .joined(separator: "\n")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tudget-export.csv")
        try? (header + rows).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

// MARK: - Categories

struct CategoriesView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context

    @Query(sort: [SortDescriptor(\BudgetCategory.sortOrder), SortDescriptor(\BudgetCategory.name)])
    private var categories: [BudgetCategory]

    @State private var showingAdd = false

    var body: some View {
        List {
            ForEach(categories) { category in
                NavigationLink {
                    CategoryEditor(category: category)
                } label: {
                    HStack {
                        Text(category.displayName)
                        Spacer()
                        Text(Currency.formatCompact(category.monthlyLimit, code: settings.homeCurrency))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    LedgerActions.deleteCategory(categories[index], in: context)
                }
            }
            .onMove(perform: move)
        }
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: {
                    Label("Add category", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        .sheet(isPresented: $showingAdd) {
            CategoryEditor(category: nil)
        }
        .overlay {
            if categories.isEmpty {
                EmptyStateView(
                    systemImage: "tray",
                    title: "No categories",
                    message: "Add a category to start budgeting by type of spend."
                )
            }
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = categories
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, category) in reordered.enumerated() {
            category.sortOrder = index
        }
        try? context.save()
        LedgerActions.publishCategorySnapshot(from: context)
    }
}

struct CategoryEditor: View {

    /// nil creates a new category; non-nil edits in place.
    let category: BudgetCategory?

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var emoji = ""
    @State private var limitText = ""

    private var isNew: Bool { category == nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Group {
            if isNew {
                NavigationStack { form.navigationTitle("New category") }
            } else {
                form.navigationTitle(name.isEmpty ? "Category" : name)
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Emoji", text: $emoji)
                HStack {
                    TextField("Monthly limit", text: $limitText)
                        .keyboardType(.decimalPad)
                    Text(settings.homeCurrency)
                        .foregroundStyle(.secondary)
                }
            }

            if isNew {
                Section {
                    Button("Add category", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear {
            // Edits to an existing category commit on the way out; a brand-new
            // one is only created by the explicit button.
            if !isNew { save() }
        }
    }

    private func load() {
        guard let category else { return }
        name = category.name
        emoji = category.emoji
        limitText = String(format: "%.0f", category.monthlyLimit)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let limit = CurrencyParser.parseNumber(limitText) ?? 0

        if let category {
            category.name = trimmedName
            category.emoji = emoji
            category.monthlyLimit = limit
        } else {
            context.insert(
                BudgetCategory(
                    name: trimmedName,
                    monthlyLimit: limit,
                    emoji: emoji,
                    sortOrder: Int(Date().timeIntervalSince1970)
                )
            )
        }

        try? context.save()
        LedgerActions.publishCategorySnapshot(from: context)
        if isNew { dismiss() }
    }
}
