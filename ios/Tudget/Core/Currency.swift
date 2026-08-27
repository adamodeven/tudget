import Foundation

/// Currency metadata: which symbols map to which ISO 4217 code, how many
/// decimal places a currency shows, and how an amount is rendered.
///
/// This mirrors `currency.py` on the Python side so a transaction logged in
/// the app and one logged by the server format identically.
enum Currency {

    /// Symbol -> ISO 4217 code. Longer, more specific symbols ("HK$") must be
    /// tried before shorter ones ("$") so they aren't shadowed -- callers
    /// should iterate `symbolsByLengthDescending` rather than this dictionary.
    static let prefixSymbols: [String: String] = [
        "US$": "USD", "C$": "CAD", "CA$": "CAD", "A$": "AUD", "AU$": "AUD",
        "NZ$": "NZD", "HK$": "HKD", "S$": "SGD", "R$": "BRL",
        "$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR",
        "₩": "KRW", "₺": "TRY", "₽": "RUB", "₴": "UAH", "₫": "VND",
        "฿": "THB", "₱": "PHP",
    ]

    static let symbolsByLengthDescending: [String] =
        prefixSymbols.keys.sorted { $0.count > $1.count }

    static let knownCodes: Set<String> = [
        "USD", "EUR", "GBP", "JPY", "INR", "KRW", "TRY", "RUB", "BRL", "UAH",
        "VND", "THB", "PHP", "SEK", "NOK", "DKK", "PLN", "CHF", "CAD", "AUD",
        "NZD", "HKD", "SGD", "MXN", "ZAR", "CNY", "AED", "ILS", "CZK", "HUF",
    ]

    /// Currencies whose smallest unit isn't a hundredth, so amounts show no
    /// decimal places.
    static let zeroDecimalCurrencies: Set<String> = ["JPY", "KRW", "VND", "HUF"]

    /// Codes conventionally displayed with a leading symbol rather than a
    /// trailing "12.47 SEK" code.
    static let displaySymbol: [String: String] = [
        "USD": "$", "CAD": "$", "AUD": "$", "NZD": "$", "HKD": "$", "SGD": "$",
        "EUR": "€", "GBP": "£", "JPY": "¥", "CNY": "¥", "INR": "₹", "KRW": "₩",
        "BRL": "R$",
    ]

    /// Codes offered in the app's currency picker, most common first, then
    /// alphabetical. The user's device currency is hoisted to the top by
    /// `pickerCodes(deviceCode:)`.
    static let commonCodes: [String] = [
        "USD", "EUR", "GBP", "JPY", "CAD", "AUD", "CHF", "CNY", "INR", "MXN",
    ]

    static var allCodesSorted: [String] {
        knownCodes.sorted()
    }

    /// Picker ordering: device currency first, then common currencies, then
    /// everything else alphabetically -- each listed only once.
    static func pickerCodes(deviceCode: String?) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        func append(_ code: String) {
            guard knownCodes.contains(code), !seen.contains(code) else { return }
            seen.insert(code)
            ordered.append(code)
        }

        if let deviceCode { append(deviceCode) }
        commonCodes.forEach(append)
        allCodesSorted.forEach(append)
        return ordered
    }

    static func decimalPlaces(for code: String) -> Int {
        zeroDecimalCurrencies.contains(code) ? 0 : 2
    }

    /// The currency of the device's current locale, if we recognize it.
    static var deviceCurrencyCode: String? {
        guard let code = Locale.current.currency?.identifier.uppercased(),
              knownCodes.contains(code) else { return nil }
        return code
    }

    /// Renders an amount the same way the Python side does: "$12.50",
    /// "€12.50", "¥1,200", "12.50 SEK".
    static func format(_ amount: Double, code: String) -> String {
        let places = decimalPlaces(for: code)

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = places
        formatter.maximumFractionDigits = places
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.usesGroupingSeparator = true

        let number = formatter.string(from: NSNumber(value: amount))
            ?? String(format: "%.\(places)f", amount)

        if let symbol = displaySymbol[code] {
            return "\(symbol)\(number)"
        }
        return "\(number) \(code)"
    }

    /// A compact form for tight spaces (widgets, list rows): drops the
    /// decimals on whole amounts so "$12.00" reads as "$12".
    static func formatCompact(_ amount: Double, code: String) -> String {
        if decimalPlaces(for: code) > 0, amount == amount.rounded() {
            let whole = format(amount, code: code)
            return whole.replacingOccurrences(of: ".00", with: "")
        }
        return format(amount, code: code)
    }
}
