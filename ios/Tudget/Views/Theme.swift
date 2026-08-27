import SwiftUI

/// One place for the app's colors, so light and dark mode stay coherent and
/// budget states (healthy / close / over) read the same everywhere.
extension Color {

    static let tudgetAccent = Color(red: 0.13, green: 0.60, blue: 0.47)
    static let tudgetWarning = Color(red: 0.90, green: 0.62, blue: 0.16)
    static let tudgetOver = Color(red: 0.85, green: 0.30, blue: 0.28)

    /// Color for a budget bar at a given fraction of its limit: green while
    /// there's room, amber past 80%, red once it's blown.
    static func budgetStatus(fractionUsed: Double, isOver: Bool) -> Color {
        if isOver { return .tudgetOver }
        if fractionUsed >= 0.8 { return .tudgetWarning }
        return .tudgetAccent
    }
}

/// A budget progress bar with the category name, spend, and remaining amount.
struct BudgetBar: View {

    let title: String
    let spent: Double
    let limit: Double
    let fractionUsed: Double
    let isOver: Bool
    let currencyCode: String

    private var statusColor: Color {
        .budgetStatus(fractionUsed: fractionUsed, isOver: isOver)
    }

    private var remainingText: String {
        let remaining = limit - spent
        if remaining >= 0 {
            return "\(Currency.formatCompact(remaining, code: currencyCode)) left"
        }
        return "\(Currency.formatCompact(abs(remaining), code: currencyCode)) over"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(remainingText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isOver ? Color.tudgetOver : .secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(statusColor)
                        .frame(width: max(0, geometry.size.width * fractionUsed))
                }
            }
            .frame(height: 8)

            Text("\(Currency.formatCompact(spent, code: currencyCode)) of \(Currency.formatCompact(limit, code: currencyCode))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(remainingText) of \(Currency.formatCompact(limit, code: currencyCode))")
    }
}

/// Empty-state placeholder used by the dashboard and history list.
struct EmptyStateView: View {

    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}
