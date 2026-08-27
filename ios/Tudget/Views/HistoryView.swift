import SwiftUI
import SwiftData

struct HistoryView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var context

    @Query(sort: \Transaction.timestamp, order: .reverse) private var transactions: [Transaction]

    @State private var search = ""
    @State private var showOnlyUncategorized = false

    private var filtered: [Transaction] {
        transactions.filter { transaction in
            if showOnlyUncategorized, transaction.category != nil { return false }
            guard !search.isEmpty else { return true }
            let needle = search.lowercased()
            return transaction.merchant.lowercased().contains(needle)
                || (transaction.category?.name.lowercased().contains(needle) ?? false)
                || (transaction.note?.lowercased().contains(needle) ?? false)
        }
    }

    /// Grouped by day, newest first -- a flat list of 200 purchases is hard to
    /// scan, and "what did I spend on Tuesday" is the usual question.
    private var grouped: [(day: Date, items: [Transaction])] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: filtered) {
            calendar.startOfDay(for: $0.timestamp)
        }
        return buckets
            .map { (day: $0.key, items: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    EmptyHint(
                        systemImage: "tray",
                        title: transactions.isEmpty ? "Nothing logged yet" : "No matches",
                        message: transactions.isEmpty
                            ? "Purchases you add will show up here."
                            : "Try a different search."
                    )
                    .padding()
                } else {
                    list
                }
            }
            .background(AmbientBackground(tint: .blue))
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Merchant, category, or note")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.smooth) { showOnlyUncategorized.toggle() }
                    } label: {
                        Image(systemName: showOnlyUncategorized
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Show only uncategorized")
                }
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Metric.cardSpacing, pinnedViews: [.sectionHeaders]) {
                ForEach(grouped, id: \.day) { group in
                    Section {
                        VStack(spacing: 0) {
                            ForEach(group.items) { transaction in
                                NavigationLink {
                                    TransactionDetailView(transaction: transaction)
                                } label: {
                                    TransactionRow(transaction: transaction)
                                }
                                .buttonStyle(.plain)

                                if transaction.id != group.items.last?.id {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                        .glassCard(radius: Theme.Metric.tightRadius)
                    } header: {
                        HStack {
                            Text(group.day, format: .dateTime.weekday(.wide).month().day())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(dayTotal(group.items))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(.horizontal, Theme.Metric.gutter)
            .padding(.bottom, 90)
        }
    }

    private func dayTotal(_ items: [Transaction]) -> String {
        let total = items.reduce(0) { $0 + $1.amountInHomeCurrency }
        return Currency.formatCompact(total, code: settings.homeCurrencyCode)
    }
}

struct TransactionRow: View {

    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((transaction.category?.tint.color ?? Color.secondary).opacity(0.22))
                Text(transaction.category?.emoji.isEmpty == false
                     ? transaction.category!.emoji
                     : "•")
                    .font(.system(size: 15))
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.displayMerchant)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    // Category identity is name + emoji, never colour alone.
                    Text(transaction.category?.name ?? "Uncategorized")
                        .foregroundStyle(transaction.category == nil ? .orange : .secondary)
                    Image(systemName: transaction.source.systemImage)
                        .foregroundStyle(.tertiary)
                    Text(transaction.timestamp, format: .dateTime.hour().minute())
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(transaction.formattedAmount)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let home = transaction.formattedHomeAmount {
                    Text(home)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 9)
        .contentShape(.rect)
    }
}
