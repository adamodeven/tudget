import Foundation

/// The container the app, the share extension, and the widgets all share.
///
/// Everything persistent lives in here rather than in the app's own sandbox,
/// so a purchase shared from the share sheet is in the ledger the instant it's
/// saved -- not queued up waiting for the app to be opened.
enum AppGroup {

    /// Must match `com.apple.security.application-groups` in every target's
    /// entitlements, which resolve `group.$(APP_BUNDLE_ID)`.
    static let identifier = "group.com.adamodeven.tudget"

    /// Shared preferences. Falls back to `.standard` only so a misconfigured
    /// App Group degrades to "the app works, the widgets look empty" instead
    /// of crashing on launch.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Where receipt and screenshot images are written.
    static var receiptsDirectory: URL? {
        guard let containerURL else { return nil }
        let directory = containerURL.appendingPathComponent("Receipts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        }
        return directory
    }

    static func receiptURL(for filename: String) -> URL? {
        receiptsDirectory?.appendingPathComponent(filename)
    }

    /// Writes image data into the shared receipts directory, returning the
    /// filename to store on the transaction. Full paths are never stored --
    /// the container URL differs between the app and its extensions.
    @discardableResult
    static func saveReceipt(_ data: Data, extension ext: String = "jpg") -> String? {
        let filename = "\(UUID().uuidString).\(ext)"
        guard let url = receiptURL(for: filename) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    static func deleteReceipt(_ filename: String) {
        guard let url = receiptURL(for: filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
