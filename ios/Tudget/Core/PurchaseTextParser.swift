import Foundation

/// Pulls a purchase out of text, from two different sources:
///
/// - `parseQuickEntry` handles what the user types ("Trader Joe's $34
///   groceries"), including an optional trailing category word.
/// - `parseNotification` handles OCR'd text off a bank or payment-app push
///   notification, where there's no category to find and the merchant is
///   buried in a sentence.
///
/// Ports `parse_manual_entry` (`inbound.py`) and `extract_purchase_from_text`
/// (`ocr.py`).
enum PurchaseTextParser {

    struct QuickEntry: Equatable {
        var merchant: String?
        var amount: Double?
        var currencyCode: String
        var category: String?
    }

    struct NotificationPurchase: Equatable {
        var merchant: String?
        var amount: Double
        var currencyCode: String
        var rawText: String
    }

    // MARK: - Typed quick entry

    static func parseQuickEntry(
        _ text: String, categoryNames: [String], defaultCurrency: String
    ) -> QuickEntry {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return QuickEntry(merchant: nil, amount: nil, currencyCode: defaultCurrency, category: nil)
        }

        var amount: Double?
        var currencyCode = defaultCurrency
        var remainder = trimmed

        if let found = CurrencyParser.findAmount(in: trimmed, defaultCurrency: defaultCurrency) {
            amount = found.value
            currencyCode = found.currencyCode
            remainder = trimmed.replacingCharacters(in: found.range, with: " ")
        }

        remainder = remainder
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " $€£¥₹"))

        guard !remainder.isEmpty else {
            return QuickEntry(merchant: nil, amount: amount, currencyCode: currencyCode, category: nil)
        }

        let words = remainder.split(separator: " ").map(String.init)
        var category: String?
        var merchantWords = words

        // Check the last word, then the last two, against the category list. A
        // high threshold avoids mistaking part of a merchant name for a
        // category, and requiring more words than we consume keeps the
        // merchant from being swallowed entirely.
        for n in [1, 2] where words.count > n {
            let candidate = words.suffix(n).joined(separator: " ")
            if let matched = CategoryMatcher.match(candidate, in: categoryNames, threshold: 0.85) {
                category = matched
                merchantWords = Array(words.dropLast(n))
                break
            }
        }

        let merchant = merchantWords
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,."))

        return QuickEntry(
            merchant: merchant.isEmpty ? nil : merchant,
            amount: amount,
            currencyCode: currencyCode,
            category: category
        )
    }

    // MARK: - OCR'd notification text

    /// Words that show up next to "at"/"to" in alert copy but are never the
    /// merchant, so a match on them is discarded rather than logged.
    private static let merchantStopWords: Set<String> = [
        "your", "the", "a", "card", "account", "checking", "savings", "you",
        "purchase", "transaction", "payment", "us", "it",
    ]

    private static let merchantPatterns: [NSRegularExpression] = {
        let patterns = [
            // "You made a $12.47 purchase at TARGET T-1234 on your card..." --
            // periods and commas are allowed inside the name itself (business
            // suffixes like "CO., LTD." are common) since the name only ends
            // at a boilerplate keyword, a status marker ("*PENDING"), or the
            // end of the text.
            #"(?:at|with|to|from)\s+([A-Z0-9][\w &'\.\-#,]{1,50}?)(?=\s+(?:on|for|using|ending|with)\b|\s*\*|\n|$)"#,
            // "New transaction: $12.47 - STARBUCKS"
            #"[:\-]\s*([A-Z][\w &'\.\-#]{2,40})\s*$"#,
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    static func parseNotification(
        _ text: String, defaultCurrency: String
    ) -> NotificationPurchase? {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }

        // The amount is the one field we refuse to guess at -- without it
        // there's nothing to log, so the caller falls back to asking the user.
        guard let found = CurrencyParser.findAmount(in: collapsed, defaultCurrency: defaultCurrency) else {
            return nil
        }

        return NotificationPurchase(
            merchant: extractMerchant(from: collapsed),
            amount: found.value,
            currencyCode: found.currencyCode,
            rawText: collapsed
        )
    }

    static func extractMerchant(from text: String) -> String? {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        for regex in merchantPatterns {
            guard let match = regex.firstMatch(in: text, range: fullRange),
                  match.numberOfRanges > 1,
                  match.range(at: 1).location != NSNotFound else { continue }

            let candidate = ns.substring(with: match.range(at: 1))
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,-"))

            guard !candidate.isEmpty,
                  !merchantStopWords.contains(candidate.lowercased()) else { continue }
            return candidate
        }

        return nil
    }
}
