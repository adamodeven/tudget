import SwiftUI
import SwiftData

struct HistoryView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context

    @Query(sort: \Transaction.timestamp, order: .reverse)
    private var transactions: [Transaction]

    @State private var searchText = ""
    @State private var showingUncategorizedOnly = false

    private var filtered: [Transaction] {
        var result = transactions

        if showingUncategorizedOnly {
            result = result.filter { !$0.isCategorized }
        }

        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            result = result.filter {
                $0.merchant.lowercased().contains(needle)
                    || ($0.category?.name.lowercased().contains(needle) ?? false)
                    || ($0.note?.lowercased().contains(needle) ?? false)
            }
        }

        return result
    }

    /// Grouped by month so scrolling back through history stays legible.
    private var sections: [(month: Date, transactions: [Transaction])] {
        let grouped = Dictionary(grouping: filtered) { transaction in
            BudgetCalculator.monthBounds(containing: transaction.timestamp).start
        }
        return grouped
            .map { (month: $0.key, transactions: $0.value) }
            .sorted { $0.month > $1.month }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    EmptyStateView(
                        systemImage: transactions.isEmpty ? "list.bullet" : "magnifyingglass",
                        title: transactions.isEmpty ? "No purchases yet" : "Nothing matches",
                        message: transactions.isEmpty
                            ? "Log your first purchase from the Budget tab."
                            : "Try a different search or clear the filter."
                    )
                } else {
                    List {
                        ForEach(sections, id: \.month) { section in
                            Section {
                                ForEach(section.transactions) { transaction in
                                    NavigationLink {
                                        TransactionDetailView(transaction: transaction)
                                    } label: {
                                        TransactionRow(transaction: transaction)
                                    }
                                    .listRowInsets(EdgeInsets())
                                }
                                .onDelete { offsets in
                                    delete(offsets, in: section.transactions)
                                }
                            } header: {
                                HStack {
                                    Text(section.month.formatted(.dateTime.month(.wide).year()))
                                    Spacer()
                                    Text(monthTotal(section.transactions))
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Search merchant or category")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingUncategorizedOnly.toggle()
                    } label: {
                        Label(
                            "Uncategorized only",
                            systemImage: showingUncategorizedOnly
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle"
                        )
                    }
                }
            }
        }
    }

    private func monthTotal(_ transactions: [Transaction]) -> String {
        let total = transactions.reduce(0) { $0 + $1.amountInHomeCurrency }
        return Currency.formatCompact(total, code: settings.homeCurrency)
    }

    private func delete(_ offsets: IndexSet, in transactions: [Transaction]) {
        for index in offsets {
            LedgerActions.delete(transactions[index], in: context)
        }
    }
}
