import Foundation
import SwiftData

/// The one SwiftData container, living in the shared App Group.
///
/// The app, the share extension, and the widgets all open *this* store. That's
/// what lets a purchase shared from the share sheet appear in the ledger and
/// on the Home Screen widget without the app ever being launched.
enum LedgerStore {

    static let schema = Schema([Transaction.self, BudgetCategory.self])

    /// Built once per process.
    ///
    /// The App Group store is the one that matters -- it's what lets the share
    /// extension and the widgets see the same ledger. But an unsigned build
    /// (the test host, most notably) has no group entitlement, and SwiftData
    /// traps rather than throwing when the container is missing. So the group
    /// container is only attempted when it actually exists, and a plain local
    /// store is the fallback: the extensions degrade, the app still runs.
    static let shared: ModelContainer = {
        if AppGroup.containerURL != nil {
            if let container = try? makeContainer(useAppGroup: true) {
                return container
            }
            print("Tudget: App Group store unavailable, falling back to a local store.")
        }

        if let container = try? makeContainer(useAppGroup: false) {
            return container
        }

        // Nothing left to try; an in-memory store keeps the process alive so
        // the failure surfaces as an empty ledger rather than a crash on launch.
        print("Tudget: on-disk store unavailable, running in memory only.")
        return try! makeContainer(inMemory: true)
    }()

    static func makeContainer(
        useAppGroup: Bool = true, inMemory: Bool = false
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration

        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if useAppGroup {
            // `cloudKitDatabase: .none` for now. The model is already
            // CloudKit-shaped, so switching this to `.automatic` and
            // uncommenting the iCloud keys in Tudget.entitlements is the whole
            // of turning sync on.
            configuration = ModelConfiguration(
                schema: schema,
                groupContainer: .identifier(AppGroup.identifier),
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        }

        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
