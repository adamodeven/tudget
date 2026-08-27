import Foundation
import SwiftData
import UserNotifications

/// Tells you a budget is getting tight, without becoming noise.
///
/// Two rules keep it trustworthy:
///
/// 1. **Each alert fires once per period.** Crossing 80% of Food notifies you
///    the first time and then stays quiet, however many more coffees you log.
///    An app that buzzes on every purchase gets its notifications turned off,
///    and then it can't warn you about anything.
/// 2. **Alerts are recomputed from state, never queued ahead.** Delete a
///    purchase and drop back under the line, and the alert becomes eligible
///    again — the record of what's fired is keyed to the period and the level.
actor BudgetNotifier {

    static let shared = BudgetNotifier()

    private let center = UNUserNotificationCenter.current()

    private enum Level: String {
        case warning   // past the warn threshold
        case over      // past the limit
        case pace      // projected to run out before the period ends
    }

    // MARK: - Authorization

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: - Refresh

    /// Recomputes which alerts are due and posts any that haven't fired yet
    /// this period. Call after anything that changes the ledger.
    @MainActor
    func refreshAlerts(context: ModelContext, settings: AppSettings) async {
        guard settings.alertsEnabled else { return }

        let period = settings.period()
        let summary = Ledger.summary(for: period, context: context, settings: settings)
        let projection = Ledger.projection(for: period, context: context, settings: settings)
        let threshold = settings.warnThreshold

        var due: [(id: String, title: String, body: String)] = []

        for category in summary.categories where category.limit > 0 {
            if category.isOverBudget {
                due.append((
                    id: "\(category.id.uuidString):\(Level.over.rawValue)",
                    title: "\(category.displayName) is over budget",
                    body: "\(Currency.formatCompact(abs(category.remaining), code: summary.homeCurrency)) over your \(Currency.formatCompact(category.limit, code: summary.homeCurrency)) limit."
                ))
            } else if category.rawFractionUsed >= threshold {
                due.append((
                    id: "\(category.id.uuidString):\(Level.warning.rawValue)",
                    title: "\(category.displayName) is running low",
                    body: "\(Currency.formatCompact(category.remaining, code: summary.homeCurrency)) left of \(Currency.formatCompact(category.limit, code: summary.homeCurrency)), with \(period.remainingDescription().lowercased())."
                ))
            }
        }

        // One overall pace warning, worth more than any single category: it's
        // the one that says the whole period is in trouble.
        if projection.pace == .willOverspend, let runOut = projection.runOutDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            due.append((
                id: "period:\(Level.pace.rawValue)",
                title: "You're spending faster than this cycle allows",
                body: "At \(Currency.formatCompact(projection.dailyBurn, code: summary.homeCurrency))/day you'd run out on \(formatter.string(from: runOut)). \(Currency.formatCompact(max(0, projection.dailyAllowance), code: summary.homeCurrency))/day keeps you on track."
            ))
        }

        await post(due, period: period)
    }

    // MARK: - Posting

    private func post(
        _ alerts: [(id: String, title: String, body: String)], period: BudgetPeriod
    ) async {
        guard await authorizationStatus() == .authorized else { return }

        let defaults = AppGroup.defaults
        let key = firedKey(for: period)
        var fired = Set(defaults.stringArray(forKey: key) ?? [])

        // A new period wipes the slate: the keys are period-scoped, so drop
        // any older ones rather than letting them accumulate forever.
        pruneOldKeys(currentKey: key, in: defaults)

        for alert in alerts where !fired.contains(alert.id) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            content.interruptionLevel = .active

            let request = UNNotificationRequest(
                identifier: "\(key):\(alert.id)",
                content: content,
                trigger: nil  // deliver now
            )

            try? await center.add(request)
            fired.insert(alert.id)
        }

        defaults.set(Array(fired), forKey: key)
    }

    private func firedKey(for period: BudgetPeriod) -> String {
        "tudget.firedAlerts.\(Int(period.start.timeIntervalSince1970))"
    }

    private func pruneOldKeys(currentKey: String, in defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("tudget.firedAlerts.") && key != currentKey {
            defaults.removeObject(forKey: key)
        }
    }

    /// Clears everything -- used when alerts are switched off.
    func cancelAll() async {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
