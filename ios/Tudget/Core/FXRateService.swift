import Foundation

/// Converts between currencies so budget totals can be tracked in one home
/// currency regardless of what a purchase was made in.
///
/// Rates come from frankfurter.app (free, no API key) and are cached on disk
/// so conversion keeps working offline and across launches. If a rate has
/// never been fetched and the network is unavailable, an approximate built-in
/// table is used rather than failing the conversion -- a slightly stale rate
/// is far better than a purchase the user can't log.
actor FXRateService {

    static let shared = FXRateService()

    private struct CachedRate: Codable {
        let rate: Double
        let fetchedAt: Date
    }

    private let cacheTTL: TimeInterval = 60 * 60  // 1 hour
    private let defaultsKey = "tudget.fxRateCache"
    private let session: URLSession

    private var cache: [String: CachedRate]

    init(session: URLSession = .shared) {
        self.session = session
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: CachedRate].self, from: data) {
            self.cache = decoded
        } else {
            self.cache = [:]
        }
    }

    /// Rate for 1 unit of `from` expressed in `to`.
    ///
    /// Returns a cached rate when it's fresh, otherwise fetches. A failed
    /// fetch falls back to a stale cached rate first (it's still the most
    /// accurate number we have) and only then to the static table.
    func rate(from: String, to: String) async -> Double {
        guard from != to else { return 1.0 }

        let key = "\(from)_\(to)"
        if let cached = cache[key],
           Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.rate
        }

        if let fetched = await fetchRate(from: from, to: to) {
            cache[key] = CachedRate(rate: fetched, fetchedAt: Date())
            persistCache()
            return fetched
        }

        if let stale = cache[key] {
            return stale.rate
        }

        return Self.fallbackRate(from: from, to: to)
    }

    func convert(_ amount: Double, from: String, to: String) async -> Double {
        guard from != to else { return amount }
        return amount * (await rate(from: from, to: to))
    }

    // MARK: - Network

    private struct FrankfurterResponse: Decodable {
        let rates: [String: Double]
    }

    private func fetchRate(from: String, to: String) async -> Double? {
        var components = URLComponents(string: "https://api.frankfurter.app/latest")
        components?.queryItems = [
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let decoded = try JSONDecoder().decode(FrankfurterResponse.self, from: data)
            return decoded.rates[to]
        } catch {
            return nil
        }
    }

    private func persistCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    // MARK: - Offline fallback

    /// Approximate value of one unit in USD. Only used when a rate has never
    /// been successfully fetched and the network is unavailable.
    private static let fallbackRatesToUSD: [String: Double] = [
        "USD": 1.0, "EUR": 1.08, "GBP": 1.27, "JPY": 0.0064, "INR": 0.012,
        "KRW": 0.00072, "TRY": 0.029, "RUB": 0.011, "BRL": 0.17, "UAH": 0.024,
        "VND": 0.00004, "THB": 0.028, "PHP": 0.017, "SEK": 0.095, "NOK": 0.091,
        "DKK": 0.145, "PLN": 0.25, "CHF": 1.11, "CAD": 0.73, "AUD": 0.66,
        "NZD": 0.60, "HKD": 0.128, "SGD": 0.74, "MXN": 0.049, "ZAR": 0.054,
        "CNY": 0.14, "AED": 0.27, "ILS": 0.27, "CZK": 0.043, "HUF": 0.0027,
    ]

    static func fallbackRate(from: String, to: String) -> Double {
        guard from != to else { return 1.0 }
        guard let fromUSD = fallbackRatesToUSD[from],
              let toUSD = fallbackRatesToUSD[to], toUSD != 0 else {
            // Nothing sensible to convert with -- treat as 1:1 so the amount
            // still lands in the ledger at its face value.
            return 1.0
        }
        return fromUSD / toUSD
    }
}
