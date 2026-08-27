import Foundation
import Observation

/// User settings, stored in the shared App Group so the widgets and the share
/// extension see exactly what the app sees.
///
/// `@Observable` so SwiftUI re-renders on change, but every property reads and
/// writes straight through to `UserDefaults` rather than caching -- an
/// extension and the app can be alive at the same time, and a cached copy in
/// either one would go stale.
@Observable
final class AppSettings {

    static let shared = AppSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    private enum Key {
        static let homeCurrency = "tudget.homeCurrency"
        static let periodLength = "tudget.periodLength"
        static let periodAnchor = "tudget.periodAnchor"
        static let takeHomePerPeriod = "tudget.takeHomePerPeriod"
        static let hasCompletedSetup = "tudget.hasCompletedSetup"
        static let alertsEnabled = "tudget.alertsEnabled"
        static let warnThreshold = "tudget.warnThreshold"
    }

    // MARK: - Currency

    /// The currency budgets are tracked in. Defaults to the device's, falling
    /// back to USD.
    var homeCurrencyCode: String {
        get { defaults.string(forKey: Key.homeCurrency) ?? Currency.deviceCurrencyCode ?? "USD" }
        set { defaults.set(newValue, forKey: Key.homeCurrency) }
    }

    // MARK: - Budget period

    var periodLength: BudgetPeriodLength {
        get {
            guard let raw = defaults.string(forKey: Key.periodLength),
                  let value = BudgetPeriodLength(rawValue: raw) else { return .biweekly }
            return value
        }
        set { defaults.set(newValue.rawValue, forKey: Key.periodLength) }
    }

    /// The day a cycle starts from. Defaults to the most recent Monday, and
    /// every fortnight tiles forward and back from there.
    var periodAnchor: Date {
        get {
            let stored = defaults.double(forKey: Key.periodAnchor)
            guard stored > 0 else { return BudgetPeriodCalculator.mondayOnOrBefore(Date()) }
            return Date(timeIntervalSince1970: stored)
        }
        set { defaults.set(newValue.timeIntervalSince1970, forKey: Key.periodAnchor) }
    }

    /// Take-home pay for one budget period, used to suggest limits in setup.
    var takeHomePerPeriod: Double {
        get { defaults.double(forKey: Key.takeHomePerPeriod) }
        set { defaults.set(newValue, forKey: Key.takeHomePerPeriod) }
    }

    var hasCompletedSetup: Bool {
        get { defaults.bool(forKey: Key.hasCompletedSetup) }
        set { defaults.set(newValue, forKey: Key.hasCompletedSetup) }
    }

    // MARK: - Alerts

    var alertsEnabled: Bool {
        get { defaults.object(forKey: Key.alertsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.alertsEnabled) }
    }

    /// Fraction of a category's limit at which it's worth saying something.
    var warnThreshold: Double {
        get {
            let stored = defaults.double(forKey: Key.warnThreshold)
            return stored > 0 ? stored : 0.8
        }
        set { defaults.set(newValue, forKey: Key.warnThreshold) }
    }

    // MARK: - Derived

    /// The period containing `date`, per the current settings.
    func period(containing date: Date = Date()) -> BudgetPeriod {
        BudgetPeriodCalculator.period(
            containing: date, anchor: periodAnchor, length: periodLength
        )
    }

    func period(offsetBy offset: Int, from date: Date = Date()) -> BudgetPeriod {
        BudgetPeriodCalculator.adjacent(
            to: period(containing: date),
            offset: offset,
            anchor: periodAnchor,
            length: periodLength
        )
    }

    /// Resets everything -- used by "Start over" in Settings.
    func reset() {
        [Key.homeCurrency, Key.periodLength, Key.periodAnchor, Key.takeHomePerPeriod,
         Key.hasCompletedSetup, Key.alertsEnabled, Key.warnThreshold]
            .forEach(defaults.removeObject(forKey:))
    }
}
