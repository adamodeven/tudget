import Foundation

/// The App Group shared between the app and the share extension.
///
/// The extension can't touch the app's SwiftData store directly (two processes
/// writing one store is asking for corruption), so the two sides talk through
/// files in this container instead:
///
///   - the app writes a **category snapshot** so the extension can offer a
///     category picker without knowing anything about SwiftData;
///   - the extension writes **pending purchases** into an inbox, which the app
///     drains into the real ledger next time it's foregrounded;
///   - **receipt images** live here so both sides can read them without copying.
enum AppGroup {

    /// Read from Info.plist (`TudgetAppGroupIdentifier`, set to
    /// `group.$(APP_BUNDLE_ID)`) so the group is configured in exactly one
    /// place -- APP_BUNDLE_ID in project.yml -- and the app and the extension
    /// can't drift apart. The literal is only a fallback for previews.
    static let identifier: String = {
        Bundle.main.object(forInfoDictionaryKey: "TudgetAppGroupIdentifier") as? String
            ?? "group.com.tudget.app"
    }()

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Shared defaults, so the extension can read the home currency the user
    /// picked in the app.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}

// MARK: - Categories the extension can show

/// A category as the share extension sees it: enough to render a picker and
/// hand an ID back, with no SwiftData dependency.
struct CategorySnapshot: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let emoji: String

    var displayName: String {
        emoji.isEmpty ? name : "\(emoji) \(name)"
    }
}

// MARK: - A purchase captured outside the app

/// Written by the share extension, drained by the app. Deliberately a flat
/// Codable value: it has to survive the app being killed, updated, or never
/// launched between capture and ingest.
struct PendingPurchase: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var merchant: String
    var amount: Double
    var currencyCode: String
    var categoryID: UUID?
    var note: String?
    var receiptFilename: String?
    var capturedAt: Date = Date()
    var sourceRaw: String = TransactionSourceKey.shareExtension
    /// The OCR text this was read from, kept so the app can show what it saw
    /// if the parse turns out to be wrong.
    var rawText: String?
}

/// String constants shared with `TransactionSource` without dragging SwiftData
/// into the extension target.
enum TransactionSourceKey {
    static let manual = "manual"
    static let screenshot = "screenshot"
    static let shareExtension = "shareExtension"
}

// MARK: - Shared file storage

enum SharedStore {

    private static let categoriesFilename = "categories.json"
    private static let inboxDirectoryName = "Inbox"
    private static let receiptsDirectoryName = "Receipts"

    private static var fileManager: FileManager { .default }

    /// Falls back to the process's own Documents directory if the App Group
    /// isn't configured, so a misconfigured entitlement degrades to
    /// "extension can't share" rather than a crash.
    private static var root: URL {
        AppGroup.containerURL
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static var receiptsDirectory: URL { directory(receiptsDirectoryName) }
    static var inboxDirectory: URL { directory(inboxDirectoryName) }

    // MARK: Category snapshot

    static func writeCategorySnapshot(_ categories: [CategorySnapshot]) {
        let url = root.appendingPathComponent(categoriesFilename)
        guard let data = try? JSONEncoder().encode(categories) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func readCategorySnapshot() -> [CategorySnapshot] {
        let url = root.appendingPathComponent(categoriesFilename)
        guard let data = try? Data(contentsOf: url),
              let categories = try? JSONDecoder().decode([CategorySnapshot].self, from: data)
        else { return [] }
        return categories
    }

    // MARK: Pending purchase inbox

    static func enqueue(_ purchase: PendingPurchase) throws {
        let url = inboxDirectory.appendingPathComponent("\(purchase.id.uuidString).json")
        let data = try JSONEncoder().encode(purchase)
        try data.write(to: url, options: .atomic)
    }

    /// Reads every queued purchase, oldest first. Files that fail to decode
    /// (a half-written capture, an older format) are dropped rather than
    /// blocking the rest of the queue forever.
    static func drainInbox() -> [PendingPurchase] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: inboxDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        var purchases: [PendingPurchase] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let purchase = try? JSONDecoder().decode(PendingPurchase.self, from: data)
            else {
                try? fileManager.removeItem(at: file)
                continue
            }
            purchases.append(purchase)
        }

        return purchases.sorted { $0.capturedAt < $1.capturedAt }
    }

    static func removeFromInbox(_ id: UUID) {
        let url = inboxDirectory.appendingPathComponent("\(id.uuidString).json")
        try? fileManager.removeItem(at: url)
    }

    // MARK: Receipt images

    /// Saves image data and returns the filename to store on the transaction.
    static func saveReceipt(_ data: Data, fileExtension: String = "jpg") throws -> String {
        let filename = "\(UUID().uuidString).\(fileExtension)"
        let url = receiptsDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return filename
    }

    static func receiptURL(_ filename: String) -> URL {
        receiptsDirectory.appendingPathComponent(filename)
    }

    static func receiptData(_ filename: String) -> Data? {
        try? Data(contentsOf: receiptURL(filename))
    }

    static func deleteReceipt(_ filename: String) {
        try? fileManager.removeItem(at: receiptURL(filename))
    }
}
