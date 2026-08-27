import Foundation
import Observation

/// User preferences, stored in the App Group's defaults so the share extension
/// reads the same home currency the app is using.
@Observable
final class AppSettings {

    static let shared = AppSettings()

    private enum Key {
        static let homeCurrency = "tudget.homeCurrency"
        static let hasCompletedSetup = "tudget.hasCompletedSetup"
        static let syncEnabled = "tudget.syncEnabled"
        static let serverBaseURL = "tudget.serverBaseURL"
        static let serverToken = "tudget.serverToken"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        self.homeCurrency = defaults.string(forKey: Key.homeCurrency)
            ?? Currency.deviceCurrencyCode
            ?? "USD"
        self.hasCompletedSetup = defaults.bool(forKey: Key.hasCompletedSetup)
        self.syncEnabled = defaults.bool(forKey: Key.syncEnabled)
        self.serverBaseURL = defaults.string(forKey: Key.serverBaseURL) ?? ""
        self.serverToken = defaults.string(forKey: Key.serverToken) ?? ""
    }

    /// The currency every budget limit and total is expressed in.
    var homeCurrency: String {
        didSet { defaults.set(homeCurrency, forKey: Key.homeCurrency) }
    }

    var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: Key.hasCompletedSetup) }
    }

    /// Optional: push transactions to the self-hosted Tudget server, which
    /// keeps the Notion dashboard, Gmail alert parsing, and Plaid
    /// reconciliation working alongside the app.
    var syncEnabled: Bool {
        didSet { defaults.set(syncEnabled, forKey: Key.syncEnabled) }
    }

    var serverBaseURL: String {
        didSet { defaults.set(serverBaseURL, forKey: Key.serverBaseURL) }
    }

    var serverToken: String {
        didSet { defaults.set(serverToken, forKey: Key.serverToken) }
    }

    /// Sync is only attempted when it's switched on and actually configured.
    var isSyncConfigured: Bool {
        syncEnabled
            && URL(string: serverBaseURL)?.scheme != nil
            && !serverToken.isEmpty
    }

    /// Read-only accessor for the share extension, which shouldn't be mutating
    /// preferences.
    static var homeCurrencyForExtension: String {
        AppGroup.defaults.string(forKey: Key.homeCurrency)
            ?? Currency.deviceCurrencyCode
            ?? "USD"
    }
}
