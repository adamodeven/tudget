import SwiftUI

/// The app's visual vocabulary.
///
/// Liquid Glass does the heavy lifting, and glass only reads as glass when
/// there's something behind it worth refracting -- so the app puts a soft,
/// slow colour field behind everything and lets the material do the rest.
/// Nothing here paints its own opaque panels.
enum Theme {

    // MARK: - Metrics

    enum Metric {
        static let cardRadius: CGFloat = 26
        static let tightRadius: CGFloat = 18
        static let chipRadius: CGFloat = 14
        static let gutter: CGFloat = 16
        static let cardSpacing: CGFloat = 14
    }

    // MARK: - Type

    /// Money is the thing you're here to read, so it gets a rounded,
    /// tabular face at a size you can take in from across the table.
    static func moneyFont(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let hero = moneyFont(52)
    static let title = moneyFont(28)
    static let figure = moneyFont(20, weight: .semibold)

    // MARK: - Status colour

    static func color(for health: BudgetCalculator.BudgetHealth) -> Color {
        switch health {
        case .healthy: return .green
        case .ahead: return .yellow
        case .critical: return .orange
        case .over: return .red
        }
    }

    static func color(for pace: RunwayProjection.Pace) -> Color {
        switch pace {
        case .onTrack: return .green
        case .willOverspend: return .orange
        case .alreadyOver: return .red
        }
    }
}

// MARK: - Background

/// The colour field everything else floats on.
///
/// It shifts with how the period is going -- green-ish when you're comfortable,
/// warm when you're spending too fast -- so the app's mood is readable before
/// you've focused on a single number.
struct AmbientBackground: View {

    var tint: Color = .blue

    var body: some View {
        ZStack {
            Color(.systemBackground)

            // Two large, soft pools of colour. Deliberately low-contrast:
            // they're here to give the glass something to bend, not to be
            // looked at.
            EllipticalGradient(
                colors: [tint.opacity(0.35), .clear],
                center: .init(x: 0.15, y: 0.05),
                startRadiusFraction: 0,
                endRadiusFraction: 0.75
            )

            EllipticalGradient(
                colors: [tint.opacity(0.18), .clear],
                center: .init(x: 0.95, y: 0.85),
                startRadiusFraction: 0,
                endRadiusFraction: 0.7
            )
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.9), value: tint)
    }
}

// MARK: - Glass surfaces

extension View {

    /// A standard glass card.
    func glassCard(radius: CGFloat = Theme.Metric.cardRadius) -> some View {
        self
            .padding(Theme.Metric.gutter)
            .glassEffect(.regular, in: .rect(cornerRadius: radius))
    }

    /// A glass card that carries a category or status colour.
    func tintedGlassCard(
        _ tint: Color, radius: CGFloat = Theme.Metric.cardRadius
    ) -> some View {
        self
            .padding(Theme.Metric.gutter)
            .glassEffect(.regular.tint(tint.opacity(0.22)), in: .rect(cornerRadius: radius))
    }

    /// A small, tappable glass pill -- category chips, quick actions.
    func glassChip(tint: Color? = nil, selected: Bool = false) -> some View {
        let base: Glass = selected
            ? .regular.tint((tint ?? .accentColor).opacity(0.55)).interactive()
            : .regular.tint((tint ?? .clear).opacity(0.18)).interactive()

        return self
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(base, in: .capsule)
    }
}

// MARK: - Progress ring

/// The per-category dial.
///
/// Reads as a ring rather than a bar because a ring makes "nearly full"
/// obvious at widget size, where a thin bar just looks like a line.
struct BudgetRing: View {

    var fraction: Double
    var tint: Color
    var lineWidth: CGFloat = 9
    /// Drawn over the ring when the category is past its limit.
    var isOver: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(
                    isOver ? AnyShapeStyle(Color.red) : AnyShapeStyle(tint.gradient),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.5), value: fraction)
        }
    }
}

// MARK: - Small building blocks

/// A label/value pair, used all over the detail surfaces.
struct StatRow: View {
    var label: String
    var value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(valueColor)
                .monospacedDigit()
        }
        .font(.subheadline)
    }
}

/// Shown wherever a list would otherwise be blank.
struct EmptyHint: View {
    var systemImage: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
