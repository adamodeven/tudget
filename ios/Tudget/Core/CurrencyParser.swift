import Foundation

/// Finds an amount and its currency in free text -- a typed entry
/// ("Cafe Luna €12,47 food") or a line of OCR'd text off a bank notification
/// ("You spent £34.99 with NETFLIX.COM").
///
/// Port of `find_amount` / `_parse_number` in `currency.py`. Rather than one
/// large alternation regex, this scans for number tokens and then inspects the
/// text immediately around each one for a symbol or ISO code, which keeps the
/// currency-detection rules readable and independently testable.
enum CurrencyParser {

    struct ParsedAmount: Equatable {
        let value: Double
        let currencyCode: String
        /// Range covering the number *and* any symbol/code attached to it, so
        /// callers can strip the whole amount out to find the merchant.
        let range: Range<String.Index>
    }

    /// Matches "1234", "12.47", "12,47", "1,234.56", "1.234,56".
    private static let numberPattern =
        #"\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?"#

    private static let numberRegex: NSRegularExpression = {
        // The pattern is a compile-time constant, so this cannot fail.
        try! NSRegularExpression(pattern: numberPattern)
    }()

    /// Parses a locale-ambiguous number string into a Double, guessing which
    /// separator is decimal from context: "1,234" -> 1234, "12,47" -> 12.47,
    /// "1.234,56" -> 1234.56, "1,234.56" -> 1234.56.
    static func parseNumber(_ raw: String) -> Double? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        let hasComma = text.contains(",")
        let hasDot = text.contains(".")

        if hasComma && hasDot {
            // Whichever separator comes last is the decimal point.
            if text.lastIndex(of: ",")! > text.lastIndex(of: ".")! {
                text = text.replacingOccurrences(of: ".", with: "")
                text = text.replacingOccurrences(of: ",", with: ".")
            } else {
                text = text.replacingOccurrences(of: ",", with: "")
            }
        } else if hasComma {
            // A trailing group of 1-2 digits is a decimal ("12,47"); a group of
            // 3 is a thousands separator ("1,234").
            let groups = text.split(separator: ",", omittingEmptySubsequences: false)
            if let last = groups.last, last.count <= 2, groups.count > 1 {
                let head = groups.dropLast().joined()
                text = head + "." + last
            } else {
                text = text.replacingOccurrences(of: ",", with: "")
            }
        }

        return Double(text)
    }

    /// Finds the first amount in `text`, falling back to `defaultCurrency` when
    /// no symbol or ISO code is attached to it.
    static func findAmount(in text: String, defaultCurrency: String) -> ParsedAmount? {
        let ns = text as NSString
        let matches = numberRegex.matches(
            in: text, range: NSRange(location: 0, length: ns.length)
        )

        for match in matches {
            guard let numberRange = Range(match.range, in: text) else { continue }
            let numberText = String(text[numberRange])
            guard let value = parseNumber(numberText) else { continue }

            let before = String(text[text.startIndex..<numberRange.lowerBound])
            let after = String(text[numberRange.upperBound...])

            if let (code, symbolLength) = leadingSymbol(before: before) {
                let start = text.index(numberRange.lowerBound, offsetBy: -symbolLength)
                return ParsedAmount(
                    value: value, currencyCode: code, range: start..<numberRange.upperBound
                )
            }

            if let (code, codeLength) = leadingCode(before: before) {
                let start = text.index(numberRange.lowerBound, offsetBy: -codeLength)
                return ParsedAmount(
                    value: value, currencyCode: code, range: start..<numberRange.upperBound
                )
            }

            if let (code, codeLength) = trailingCode(after: after) {
                let end = text.index(numberRange.upperBound, offsetBy: codeLength)
                return ParsedAmount(
                    value: value, currencyCode: code, range: numberRange.lowerBound..<end
                )
            }

            return ParsedAmount(
                value: value, currencyCode: defaultCurrency, range: numberRange
            )
        }

        return nil
    }

    /// Convenience for callers that don't need the range.
    static func parseAmountAndCurrency(
        in text: String, defaultCurrency: String
    ) -> (amount: Double, currencyCode: String)? {
        guard let found = findAmount(in: text, defaultCurrency: defaultCurrency) else {
            return nil
        }
        return (found.value, found.currencyCode)
    }

    // MARK: - Context inspection

    /// A currency symbol directly before the number, optionally separated by a
    /// single space ("€12,47", "US$ 40"). Returns the code and how many
    /// characters to walk back to include the symbol and that space.
    private static func leadingSymbol(before: String) -> (code: String, length: Int)? {
        let trimmed = before.hasSuffix(" ") ? String(before.dropLast()) : before
        let spacing = before.count - trimmed.count

        for symbol in Currency.symbolsByLengthDescending where trimmed.hasSuffix(symbol) {
            guard let code = Currency.prefixSymbols[symbol] else { continue }
            return (code, symbol.count + spacing)
        }
        return nil
    }

    /// An ISO code directly before the number ("EUR 12.47").
    private static func leadingCode(before: String) -> (code: String, length: Int)? {
        let trimmed = before.hasSuffix(" ") ? String(before.dropLast()) : before
        let spacing = before.count - trimmed.count

        guard trimmed.count >= 3 else { return nil }
        let code = String(trimmed.suffix(3))
        guard isIsolatedCode(code, precededBy: trimmed.dropLast(3).last) else { return nil }
        return (code, 3 + spacing)
    }

    /// An ISO code directly after the number ("12.47 EUR").
    private static func trailingCode(after: String) -> (code: String, length: Int)? {
        let trimmed = after.hasPrefix(" ") ? String(after.dropFirst()) : after
        let spacing = after.count - trimmed.count

        guard trimmed.count >= 3 else { return nil }
        let code = String(trimmed.prefix(3))
        guard isIsolatedCode(code, followedBy: trimmed.dropFirst(3).first) else { return nil }
        return (code, 3 + spacing)
    }

    /// A three-letter run only counts as a currency code if we know it and it
    /// isn't part of a longer word ("EUROPE" must not read as "EUR").
    private static func isIsolatedCode(
        _ code: String, precededBy previous: Character? = nil, followedBy next: Character? = nil
    ) -> Bool {
        guard Currency.knownCodes.contains(code.uppercased()),
              code == code.uppercased() else { return false }
        if let previous, previous.isLetter { return false }
        if let next, next.isLetter { return false }
        return true
    }
}
