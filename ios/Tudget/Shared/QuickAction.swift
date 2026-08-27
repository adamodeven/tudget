import Foundation

/// A request to open the app straight into a capture flow.
///
/// The Control Center button and the widgets can't present the app's own
/// sheets, so they leave a note here and the app picks it up the moment it
/// becomes active. Stored in the App Group rather than passed through the URL
/// alone so a cold launch and a resume behave identically.
enum QuickAction: String, Sendable {
    case quickAdd
    case screenshot

    private static let key = "tudget.pendingQuickAction"

    /// Deep link equivalent, for widgets, which open URLs rather than run
    /// intents.
    var url: URL {
        URL(string: "tudget://\(rawValue)")!
    }

    init?(url: URL) {
        guard url.scheme == "tudget" else { return nil }
        // Accept both tudget://quickAdd and tudget:///quickAdd.
        let name = url.host ?? url.pathComponents.last(where: { $0 != "/" })
        guard let name, let action = QuickAction(rawValue: name) else { return nil }
        self = action
    }

    static func request(_ action: QuickAction, in defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(action.rawValue, forKey: key)
    }

    /// Reads and clears the pending action, so it fires exactly once.
    static func consume(in defaults: UserDefaults = AppGroup.defaults) -> QuickAction? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        defaults.removeObject(forKey: key)
        return QuickAction(rawValue: raw)
    }
}
