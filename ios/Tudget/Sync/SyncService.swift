import Foundation
import SwiftData

/// Optional one-way push of purchases to the self-hosted Tudget server.
///
/// The app is the source of truth and works entirely offline; this exists so
/// the server-side pieces that a phone can't do -- the Notion dashboard,
/// bank-alert email parsing, Plaid reconciliation -- keep seeing everything
/// logged on the phone. Nothing here is required for the app to function, and
/// a failed sync never blocks or loses a purchase: unsynced rows simply keep
/// their `syncedAt` nil and go out on the next attempt.
enum SyncService {

    struct TransactionPayload: Encodable {
        let id: String
        let merchant: String
        let amount: Double
        let currency: String
        let amount_default_currency: Double
        let card: String
        let category: String?
        let timestamp: String
        let source: String
        let note: String?
    }

    enum SyncError: LocalizedError {
        case notConfigured
        case badResponse(Int)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Set a server URL and API token first."
            case .badResponse(let code):
                return "Server returned \(code)."
            case .transport(let error):
                return error.localizedDescription
            }
        }
    }

    /// Pushes every transaction that hasn't been synced yet. Returns how many
    /// went out.
    @MainActor
    static func syncPending(
        in context: ModelContext, settings: AppSettings
    ) async -> Result<Int, SyncError> {
        guard settings.isSyncConfigured,
              let baseURL = URL(string: settings.serverBaseURL) else {
            return .failure(.notConfigured)
        }

        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.syncedAt == nil },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else {
            return .success(0)
        }

        let formatter = ISO8601DateFormatter()
        let payloads = pending.map { transaction in
            TransactionPayload(
                id: transaction.uuid.uuidString,
                merchant: transaction.merchant,
                amount: transaction.amount,
                currency: transaction.currencyCode,
                amount_default_currency: transaction.amountInHomeCurrency,
                card: transaction.card,
                category: transaction.category?.name,
                timestamp: formatter.string(from: transaction.timestamp),
                source: transaction.source.rawValue,
                note: transaction.note
            )
        }

        do {
            try await post(
                payloads,
                to: baseURL.appendingPathComponent("api/transactions"),
                token: settings.serverToken
            )
        } catch let error as SyncError {
            return .failure(error)
        } catch {
            return .failure(.transport(error))
        }

        let now = Date()
        for transaction in pending {
            transaction.syncedAt = now
        }
        try? context.save()

        return .success(pending.count)
    }

    private static func post(
        _ payloads: [TransactionPayload], to url: URL, token: String
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["transactions": payloads])
        request.timeoutInterval = 30

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SyncError.badResponse(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncError.badResponse(http.statusCode)
        }
    }
}
