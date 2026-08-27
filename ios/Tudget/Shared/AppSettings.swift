import Foundation
import Observation

/// User settings, persisted to the shared App Group so the widgets and the
/// share extension see exactly what the app sees.
///
/// **These are stored properties that write through on `didSet`, not computed
/// properties over `UserDefaults`.** That distinction is load-bearing:
/// `@Observable` only generates change tracking for stored properties, so a
/// computed-property version compiles, persists correctly, and silently never
/// redraws anything -- which strands you on the setup screen when you finish
/// setup, because the view reading `hasCompletedSetup` is never invalidated.
///
/// Each process loads its own copy at init. Nothing but the app writes
/// settings, and extensions are short-lived, so a stale copy isn't reachable
/// in practice; `reload()` is there for the case where it ever becomes so.
@Observable
final class AppSettings {

    @MainActor static let shared = AppSettings()

    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let homeCurrency = "tudget.homeCurrency"
        static let periodLength = "tudget.periodLength"
        static let periodAnchor = "tudget.periodAnchor"
        static let takeHomePerPeriod = "tudget.takeHomePerPeriod"
        static let hasCompletedSetup = "tudget.hasCompletedSetup"
        static let alertsEnabled = "tudget.alertsEnabled"
        static let warnThreshold = "tudget.warnThreshold"
    }

    // MARK: - Stored settings

    /// The currency budgets are tracked in.
    var homeCurrencyCode: String {
        didSet { defaults.set(homeCurrencyCode, forKey: Key.homeCurrency) }
    }

    var periodLength: BudgetPeriodLength {
        didSet { defaults.set(periodLength.rawValue, forKey: Key.periodLength) }
    }

    /// The day a cycle starts from. Fortnights tile forward and back from here.
    var periodAnchor: Date {
        didSet { defaults.set(periodAnchor.timeIntervalSince1970, forKey: Key.periodAnchor) }
    }

    /// Take-home pay for one budget period, used to suggest limits in setup.
    var takeHomePerPeriod: Double {
        didSet { defaults.set(takeHomePerPeriod, forKey: Key.takeHomePerPeriod) }
    }

    var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: Key.hasCompletedSetup) }
    }

    var alertsEnabled: Bool {
        didSet { defaults.set(alertsEnabled, forKey: Key.alertsEnabled) }
    }

    /// Fraction of a category's limit at which it's worth saying something.
    var warnThreshold: Double {
        didSet { defaults.set(warnThreshold, forKey: Key.warnThreshold) }
    }

    // MARK: - Init

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults

        self.homeCurrencyCode = defaults.string(forKey: Key.homeCurrency)
            ?? Currency.deviceCurrencyCode ?? "USD"

        self.periodLength = defaults.string(forKey: Key.periodLength)
            .flatMap(BudgetPeriodLength.init(rawValue:)) ?? .biweekly

        let storedAnchor = defaults.double(forKey: Key.periodAnchor)
        self.periodAnchor = storedAnchor > 0
            ? Date(timeIntervalSince1970: storedAnchor)
            : BudgetPeriodCalculator.mondayOnOrBefore(Date())

        self.takeHomePerPeriod = defaults.double(forKey: Key.takeHomePerPeriod)
        self.hasCompletedSetup = defaults.bool(forKey: Key.hasCompletedSetup)
        self.alertsEnabled = defaults.object(forKey: Key.alertsEnabled) as? Bool ?? true

        let storedThreshold = defaults.double(forKey: Key.warnThreshold)
        self.warnThreshold = storedThreshold > 0 ? storedThreshold : 0.8
    }

    /// Re-reads everything from disk, for the case where another process has
    /// written since this copy was made.
    func reload() {
        let fresh = AppSettings(defaults: defaults)
        homeCurrencyCode = fresh.homeCurrencyCode
        periodLength = fresh.periodLength
        periodAnchor = fresh.periodAnchor
        takeHomePerPeriod = fresh.takeHomePerPeriod
        hasCompletedSetup = fresh.hasCompletedSetup
        alertsEnabled = fresh.alertsEnabled
        warnThreshold = fresh.warnThreshold
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

    /// Clears everything -- used by "Start over" in Settings.
    func reset() {
        [Key.homeCurrency, Key.periodLength, Key.periodAnchor, Key.takeHomePerPeriod,
         Key.hasCompletedSetup, Key.alertsEnabled, Key.warnThreshold]
            .forEach(defaults.removeObject(forKey:))
        reload()
    }
}
