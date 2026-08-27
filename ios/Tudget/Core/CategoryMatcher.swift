import Foundation

/// Maps free text onto a budget category.
///
/// Used by quick-entry ("Trader Joe's $34 groceries") and by the share
/// extension, where the user types rather than taps. Exact and alias matches
/// come first; anything else falls back to a normalized edit-distance score so
/// small typos ("grocries") still land. Port of `match_category` in
/// `inbound.py`, with rapidfuzz's WRatio replaced by Levenshtein similarity.
enum CategoryMatcher {

    /// Synonyms layered on top of whatever category names the user actually
    /// has, so casual words map correctly even when they share no characters
    /// with the category name ("grub" -> Food).
    static let aliases: [String: [String]] = [
        "food": ["food", "groceries", "grocery", "eating", "eat", "grub", "snacks",
                 "lunch", "dinner", "breakfast", "coffee"],
        "going out": ["going out", "dining out", "drinks", "bar", "bars", "fun",
                      "entertainment", "social", "nightlife", "restaurant"],
        "transport": ["transport", "transportation", "uber", "lyft", "gas", "gasoline",
                      "commute", "transit", "taxi", "cab", "parking", "train", "bus"],
        "shopping": ["shopping", "shop", "clothes", "clothing", "retail", "amazon"],
        "subscriptions": ["subscriptions", "subscription", "subs", "streaming",
                          "recurring", "membership"],
        "other": ["other", "misc", "miscellaneous"],
    ]

    /// Every search term for a set of category names, as (term, categoryName).
    private static func searchTerms(for categoryNames: [String]) -> [(term: String, category: String)] {
        var terms: [(String, String)] = []
        for name in categoryNames {
            let lowered = name.lowercased()
            terms.append((lowered, name))
            for alias in aliases[lowered] ?? [] {
                terms.append((alias, name))
            }
        }
        return terms
    }

    /// Best matching category name, or nil if nothing scores above `threshold`
    /// (0...1 similarity).
    static func match(
        _ text: String, in categoryNames: [String], threshold: Double = 0.7
    ) -> String? {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, !categoryNames.isEmpty else { return nil }

        let terms = searchTerms(for: categoryNames)

        // Exact hit on a name or alias always wins outright.
        if let exact = terms.first(where: { $0.term == needle }) {
            return exact.category
        }

        var best: (category: String, score: Double)?
        for (term, category) in terms {
            let score = similarity(needle, term)
            if score > (best?.score ?? 0) {
                best = (category, score)
            }
        }

        guard let best, best.score >= threshold else { return nil }
        return best.category
    }

    /// Normalized Levenshtein similarity in 0...1, where 1 is an exact match.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }

        let distance = levenshtein(Array(a), Array(b))
        let longest = max(a.count, b.count)
        return 1.0 - (Double(distance) / Double(longest))
    }

    /// Standard two-row Levenshtein edit distance.
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitutionCost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,                   // deletion
                    current[j - 1] + 1,                // insertion
                    previous[j - 1] + substitutionCost // substitution
                )
            }
            swap(&previous, &current)
        }

        return previous[b.count]
    }
}
