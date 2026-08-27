import AppIntents

/// Opens the app straight into the one-line purchase entry.
///
/// Used by the Control Centre button, the Lock Screen control, and Siri. It
/// can't present the app's sheet itself, so it leaves a request in the shared
/// App Group and the app picks it up as it becomes active.
struct OpenQuickAddIntent: AppIntent {

    static let title: LocalizedStringResource = "Add a Purchase"
    static let description = IntentDescription(
        "Opens Tudget ready to log a purchase.",
        categoryName: "Capture"
    )

    /// The whole point: get to the keyboard, not to a launch screen.
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        QuickAction.request(.quickAdd)
        return .result()
    }
}

/// Opens the app on the screenshot importer.
struct OpenScreenshotImportIntent: AppIntent {

    static let title: LocalizedStringResource = "Add From a Screenshot"
    static let description = IntentDescription(
        "Opens Tudget ready to read a purchase off a screenshot.",
        categoryName: "Capture"
    )

    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        QuickAction.request(.screenshot)
        return .result()
    }
}

/// Makes both intents discoverable in Shortcuts and Spotlight.
struct TudgetShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenQuickAddIntent(),
            phrases: [
                "Add a purchase to \(.applicationName)",
                "Log a purchase in \(.applicationName)",
                "New purchase in \(.applicationName)",
            ],
            shortTitle: "Add a Purchase",
            systemImageName: "plus.circle.fill"
        )
        AppShortcut(
            intent: OpenScreenshotImportIntent(),
            phrases: [
                "Add a screenshot to \(.applicationName)",
                "Scan a purchase in \(.applicationName)",
            ],
            shortTitle: "From a Screenshot",
            systemImageName: "camera.viewfinder"
        )
    }
}
