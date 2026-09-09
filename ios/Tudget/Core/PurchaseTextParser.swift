import Foundation

/// Pulls a purchase out of text, from several different sources:
///
/// - `parseQuickEntry` handles the terse one-line grammar ("Trader Joe's $34
///   groceries"), including an optional trailing category word.
/// - `parseSpokenEntry` handles a dictated sentence, which is the same thing
///   wrapped in scaffolding ("I spent thirty four dollars at Trader Joe's on
///   groceries") -- it normalizes that and defers to `parseQuickEntry`.
/// - `parseNotification` handles OCR'd text off a bank or payment-app push
///   notification, where there's no category to find and the merchant is
///   buried in a sentence.
/// - `parseScreenshot` handles a screenshot's recognized lines, where the
///   merchant may instead sit on its own line near the amount.
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

    // MARK: - Spoken entry

    /// Parses a dictated sentence.
    ///
    /// Speaking a purchase produces something much looser than the line
    /// someone types: a whole sentence ("I spent thirty four dollars at Trader
    /// Joe's on groceries"), with the amount formatted however the recognizer
    /// felt like formatting it that time -- "$34" on one pass, "34 dollars" on
    /// the next. Both are rewritten into the typed grammar and handed to
    /// `parseQuickEntry`, so there is still exactly one place that knows how
    /// to read a purchase out of text.
    static func parseSpokenEntry(
        _ text: String, categoryNames: [String], defaultCurrency: String
    ) -> QuickEntry {
        var entry = parseQuickEntry(
            normalizeSpoken(text),
            categoryNames: categoryNames,
            defaultCurrency: defaultCurrency
        )
        entry.merchant = entry.merchant.flatMap(strippingFillers)
        return entry
    }

    /// Spoken currency names, which the recognizer leaves as words whenever it
    /// doesn't collapse them into a symbol.
    private static let spokenCurrencies: [String: String] = [
        "dollar": "USD", "dollars": "USD", "buck": "USD", "bucks": "USD",
        "euro": "EUR", "euros": "EUR",
        "pound": "GBP", "pounds": "GBP", "quid": "GBP",
        "yen": "JPY",
        "rupee": "INR", "rupees": "INR",
    ]

    /// "60 bucks", "8 euros", "12 dollars and 40 cents" -- a number, the
    /// currency said out loud after it, and optionally the cents said after
    /// that.
    private static let spokenAmountRegex: NSRegularExpression? = {
        let words = spokenCurrencies.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        return try? NSRegularExpression(
            pattern: #"(\d+)\s*(\#(words))\b(?:\s+and)?(?:\s+(\d{1,2})\s*cents?\b)?"#,
            options: [.caseInsensitive]
        )
    }()

    /// "fifty cents", with no currency word in front of it. A separate pass,
    /// because without it that number reads as fifty *dollars* -- a hundred
    /// times the purchase, logged without a murmur.
    private static let spokenCentsRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\b(\d{1,2})\s*cents?\b"#, options: [.caseInsensitive])
    }()

    /// Sentence scaffolding that carries no information about the purchase.
    /// Stripped only from the ends of the merchant, so a name that happens to
    /// contain one of these ("Bed Bath & Beyond") survives intact.
    private static let spokenFillers: Set<String> = [
        "i", "my", "me", "we", "it", "just", "please", "and", "then",
        "spent", "spend", "paid", "pay", "bought", "buy", "add", "adding",
        "log", "logged", "put", "was", "were", "for", "on", "at", "from",
        "to", "in", "of", "with", "a", "an", "the", "some", "this", "that",
        "purchase", "purchased", "expense", "there", "here", "down",
    ]

    /// Rewrites a dictated sentence into something `parseQuickEntry` reads the
    /// same way it reads a typed one.
    private static func normalizeSpoken(_ text: String) -> String {
        var normalized = collapseWhitespace(text)

        // "12 dollars and 40 cents" -> "12.40 USD", which the amount scanner
        // already knows how to read as a number with a trailing ISO code.
        if let regex = spokenAmountRegex {
            normalized = rewriting(normalized, matching: regex) { groups in
                guard let code = spokenCurrencies[groups[2].lowercased()] else { return nil }
                return "\(groups[1])\(decimalFraction(groups[3])) \(code)"
            }
        }

        if let regex = spokenCentsRegex {
            normalized = rewriting(normalized, matching: regex) { groups in
                "0\(decimalFraction(groups[1]))"
            }
        }

        // Dictation ends sentences even when you didn't ask it to.
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:"))
    }

    /// "40" -> ".40", "5" -> ".05", "" -> "". Spoken cents are a count out of
    /// a hundred, so a single digit is the tens place and not the units.
    private static func decimalFraction(_ cents: String) -> String {
        guard !cents.isEmpty else { return "" }
        return "." + (cents.count == 1 ? "0" + cents : cents)
    }

    /// Replaces every match, last one first so the ranges ahead of the one
    /// being replaced stay where the regex said they were.
    private static func rewriting(
        _ text: String,
        matching regex: NSRegularExpression,
        with replacement: ([String]) -> String?
    ) -> String {
        let ns = text as NSString
        var result = text

        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            guard let replaced = replacement(groups),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replaced)
        }

        return result
    }

    /// Eats filler words off both ends of a merchant guess, and gives up on it
    /// entirely if that's all it was.
    private static func strippingFillers(_ merchant: String) -> String? {
        var words = merchant.split(separator: " ").map(String.init)

        while let first = words.first,
              spokenFillers.contains(normalizedWord(first)) { words.removeFirst() }
        while let last = words.last,
              spokenFillers.contains(normalizedWord(last)) { words.removeLast() }

        let cleaned = words.joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func normalizedWord(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:")).lowercased()
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

            // A joined screenshot runs the alert's sentence into whatever else
            // was on screen, so a match can pick up a trailing timestamp; drop
            // that tail before giving up on the name in front of it.
            let raw = ns.substring(with: match.range(at: 1))
            if let candidate = merchantCandidate(raw)
                ?? merchantCandidate(droppingTrailingNoise(raw)) {
                return candidate
            }
        }

        return nil
    }

    // MARK: - Screenshot layout

    /// Parses the lines Vision read off a screenshot.
    ///
    /// Bank alerts write the purchase as a sentence, which `parseNotification`
    /// handles once the lines are joined. App screens don't: a transaction row
    /// or detail view puts the merchant on one line and the amount on another,
    /// with no "at"/"to" between them to key off. So when the sentence
    /// patterns come up empty, the layout itself is the clue.
    static func parseScreenshot(
        lines: [String], defaultCurrency: String
    ) -> NotificationPurchase? {
        let cleaned = lines.map(collapseWhitespace).filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }

        let joined = cleaned.joined(separator: " ")
        guard let found = CurrencyParser.findAmount(
            in: joined, defaultCurrency: defaultCurrency
        ) else { return nil }

        let merchant = extractMerchant(from: joined)
            ?? merchantFromLayout(of: cleaned, amount: found, defaultCurrency: defaultCurrency)

        return NotificationPurchase(
            merchant: merchant,
            amount: found.value,
            currencyCode: found.currencyCode,
            rawText: joined
        )
    }

    /// Looks for the merchant around whichever line carries the amount: beside
    /// it on that line ("STARBUCKS  $5.75"), then on the lines above -- where a
    /// detail screen and a transaction row both put the name -- and only then
    /// below it.
    private static func merchantFromLayout(
        of lines: [String], amount: CurrencyParser.ParsedAmount, defaultCurrency: String
    ) -> String? {
        guard let index = lines.firstIndex(where: { line in
            guard let found = CurrencyParser.findAmount(
                in: line, defaultCurrency: defaultCurrency
            ) else { return false }
            return found.value == amount.value && found.currencyCode == amount.currencyCode
        }) else { return nil }

        let amountLine = lines[index]
        if let found = CurrencyParser.findAmount(in: amountLine, defaultCurrency: defaultCurrency),
           let merchant = merchantCandidate(amountLine.replacingCharacters(in: found.range, with: " ")) {
            return merchant
        }

        // Nearest first in each direction, and no further than a few lines --
        // past that we're reading unrelated chrome rather than this purchase.
        let above = stride(from: index - 1, through: max(index - 3, 0), by: -1)
        let below = stride(from: index + 1, through: min(index + 3, lines.count - 1), by: 1)
        for i in Array(above) + Array(below) {
            if let merchant = merchantCandidate(lines[i]) { return merchant }
        }

        return nil
    }

    /// Text that shows up next to an amount in banking UI but is never a
    /// merchant name. Matched as a substring, so "Chase Credit Card" and
    /// "Card ending in 4242" both fall out.
    private static let nonMerchantPhrases: [String] = [
        "pending", "posted", "declined", "authorized", "authorised",
        "transaction", "purchase", "payment", "details", "amount", "total",
        "balance", "available", "credit card", "debit card", "ending in",
        "account", "apple pay", "google pay", "notification", "yesterday",
        "today", "just now",
    ]

    private static let nonMerchantLinePatterns: [NSRegularExpression] = {
        let patterns = [
            #"\d{1,2}:\d{2}"#,                                     // a clock time
            #"\b\d+\s*(?:s|m|h|d|min|mins|hr|hrs|hours?|days?|weeks?)\s+ago\b"#,
            #"^\d{1,2}[/.-]\d{1,2}(?:[/.-]\d{2,4})?$"#,             // 9/12, 09/12/2025
            #"^(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}"#,
            #"^(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\s"#,
            #"[•*]{2,}\s*\d"#,                                     // •••• 4242
            #"\b(?:bank|visa|mastercard|amex)\b"#,
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    /// Single-character symbols only: "US$" would otherwise make every U and S
    /// look like money.
    private static let currencySymbolCharacters: Set<Character> =
        Set(Currency.prefixSymbols.keys.filter { $0.count == 1 }.joined())

    /// Cleans up a merchant guess and rejects it if it reads as anything but a
    /// name -- a date, a card number, a second amount, or UI boilerplate.
    private static func merchantCandidate(_ text: String) -> String? {
        let candidate = collapseWhitespace(text)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,:;-–—*#|"))
        guard candidate.count >= 2, candidate.count <= 60,
              candidate.filter(\.isLetter).count >= 2 else { return nil }

        let lowered = candidate.lowercased()
        guard !merchantStopWords.contains(lowered),
              !nonMerchantPhrases.contains(where: { lowered.contains($0) }),
              !candidate.contains(where: { currencySymbolCharacters.contains($0) }) else {
            return nil
        }

        // Digits inside a name are fine ("7-ELEVEN 2841"); a line that is
        // mostly digits is a date, a card number, or another amount.
        let visible = candidate.filter { !$0.isWhitespace }.count
        guard candidate.filter(\.isNumber).count * 2 < visible else { return nil }

        let range = NSRange(location: 0, length: (candidate as NSString).length)
        for regex in nonMerchantLinePatterns
        where regex.firstMatch(in: candidate, range: range) != nil {
            return nil
        }

        return candidate
    }

    /// Boilerplate that trails a merchant name once lines are run together --
    /// a timestamp, a date, a status word -- along with everything after it.
    private static let trailingNoisePatterns: [NSRegularExpression] = {
        let patterns = [
            #"\s+\d+\s*(?:s|m|h|d|min|mins|hr|hrs|hours?|days?|weeks?)\s+ago\b.*$"#,
            #"\s+\d{1,2}:\d{2}.*$"#,
            #"\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}\b.*$"#,
            #"\s+(?:today|yesterday|just now|pending|posted|declined)\b.*$"#,
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()

    private static func droppingTrailingNoise(_ text: String) -> String {
        trailingNoisePatterns.reduce(text) { partial, regex in
            regex.stringByReplacingMatches(
                in: partial,
                range: NSRange(location: 0, length: (partial as NSString).length),
                withTemplate: ""
            )
        }
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
