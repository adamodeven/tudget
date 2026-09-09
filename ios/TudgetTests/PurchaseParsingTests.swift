import XCTest
@testable import Tudget

private let categories = ["Food", "Going Out", "Transport", "Shopping"]

/// Mirrors `tests/test_inbound.py`.
final class QuickEntryTests: XCTestCase {

    private func parse(_ text: String, default defaultCurrency: String = "USD")
        -> PurchaseTextParser.QuickEntry {
        PurchaseTextParser.parseQuickEntry(
            text, categoryNames: categories, defaultCurrency: defaultCurrency
        )
    }

    func testMerchantAmountAndTrailingCategory() {
        let result = parse("Trader Joe's $34 groceries")
        XCTAssertEqual(result.merchant, "Trader Joe's")
        XCTAssertEqual(result.amount, 34)
        XCTAssertEqual(result.currencyCode, "USD")
        XCTAssertEqual(result.category, "Food")
    }

    func testLeadingAmountWithTwoWordCategory() {
        let result = parse("$12 coffee going out")
        XCTAssertEqual(result.amount, 12)
        XCTAssertEqual(result.category, "Going Out")
        XCTAssertEqual(result.merchant, "coffee")
    }

    func testForeignCurrency() {
        let result = parse("Cafe Luna €12,47 food")
        XCTAssertEqual(result.merchant, "Cafe Luna")
        XCTAssertEqual(result.amount, 12.47)
        XCTAssertEqual(result.currencyCode, "EUR")
        XCTAssertEqual(result.category, "Food")
    }

    /// An unrecognized trailing word stays part of the merchant rather than
    /// being silently dropped.
    func testUnknownTrailingWordStaysInMerchant() {
        let result = parse("CVS $8.50 health")
        XCTAssertEqual(result.merchant, "CVS health")
        XCTAssertEqual(result.amount, 8.50)
        XCTAssertNil(result.category)
    }

    func testMissingAmount() {
        let result = parse("Trader Joe's groceries")
        XCTAssertNil(result.amount)
    }

    func testEmptyInput() {
        let result = parse("   ")
        XCTAssertNil(result.amount)
        XCTAssertNil(result.merchant)
    }

    /// A category word must never consume the entire merchant.
    func testCategoryOnlyInputKeepsMerchant() {
        let result = parse("$20 food")
        XCTAssertEqual(result.amount, 20)
        XCTAssertNotNil(result.merchant)
    }
}

/// Dictation is looser than typing: whole sentences, and an amount formatted
/// however the recognizer felt like formatting it that pass.
final class SpokenEntryTests: XCTestCase {

    private func parse(_ text: String, default defaultCurrency: String = "USD")
        -> PurchaseTextParser.QuickEntry {
        PurchaseTextParser.parseSpokenEntry(
            text, categoryNames: categories, defaultCurrency: defaultCurrency
        )
    }

    /// What the recognizer usually gives back, having formatted the amount.
    func testFormattedSentence() {
        let result = parse("I spent $34 at Trader Joe's on groceries")
        XCTAssertEqual(result.merchant, "Trader Joe's")
        XCTAssertEqual(result.amount, 34)
        XCTAssertEqual(result.currencyCode, "USD")
        XCTAssertEqual(result.category, "Food")
    }

    /// And what it gives back when it doesn't.
    func testSpokenCurrencyWord() {
        let result = parse("12 dollars at Blue Bottle")
        XCTAssertEqual(result.merchant, "Blue Bottle")
        XCTAssertEqual(result.amount, 12)
        XCTAssertEqual(result.currencyCode, "USD")
    }

    /// Said aloud in full. Getting this wrong loses the cents silently, which
    /// is the kind of error nobody catches until the totals drift.
    func testDollarsAndCents() {
        let result = parse("I spent 12 dollars and 40 cents at Blue Bottle on food")
        XCTAssertEqual(result.merchant, "Blue Bottle")
        XCTAssertEqual(result.amount, 12.40)
        XCTAssertEqual(result.currencyCode, "USD")
        XCTAssertEqual(result.category, "Food")
    }

    /// A single spoken cents digit is the tens place: "five cents" is 0.05.
    func testSingleCentsDigit() {
        XCTAssertEqual(parse("9 dollars and 5 cents at Shell").amount, 9.05)
    }

    /// And cents with no dollars in front of them are not dollars, which is
    /// the difference between 75c and $75.
    func testBareCents() {
        let result = parse("75 cents at the Corner Store")
        XCTAssertEqual(result.amount, 0.75)
        XCTAssertEqual(result.merchant, "Corner Store")
    }

    func testSpokenForeignCurrencyBeatsTheDefault() {
        let result = parse("15 euros at Cafe Luna")
        XCTAssertEqual(result.merchant, "Cafe Luna")
        XCTAssertEqual(result.amount, 15)
        XCTAssertEqual(result.currencyCode, "EUR")
    }

    /// The full stop dictation adds doesn't become part of anything, and a
    /// word that is only a category leaves no merchant behind rather than a
    /// merchant called "Paid for".
    func testTrailingPunctuationAndFiller() {
        let result = parse("Paid £8.50 for parking.")
        XCTAssertEqual(result.amount, 8.5)
        XCTAssertEqual(result.currencyCode, "GBP")
        XCTAssertEqual(result.category, "Transport")
        XCTAssertNil(result.merchant)
    }

    /// A filler word inside a name is not scaffolding and stays put.
    func testFillerInsideAMerchantSurvives() {
        let result = parse("$20 at Bed Bath and Beyond")
        XCTAssertEqual(result.merchant, "Bed Bath and Beyond")
        XCTAssertEqual(result.amount, 20)
    }

    func testCategorySpokenAfterTheMerchant() {
        let result = parse("I paid 60 bucks for gas at Shell transport")
        XCTAssertEqual(result.amount, 60)
        XCTAssertEqual(result.currencyCode, "USD")
        XCTAssertEqual(result.category, "Transport")
    }

    /// Nothing but scaffolding is no merchant at all, rather than a merchant
    /// called "at the".
    func testSentenceWithNoMerchant() {
        let result = parse("I spent $9 on food")
        XCTAssertNil(result.merchant)
        XCTAssertEqual(result.amount, 9)
        XCTAssertEqual(result.category, "Food")
    }

    /// Nothing said, or nothing numeric said: the caller has to be able to
    /// tell, because there is nothing to log without an amount.
    func testNoAmountLeavesNilAmount() {
        XCTAssertNil(parse("coffee at Blue Bottle").amount)
        XCTAssertNil(parse("").amount)
    }
}


/// Mirrors `tests/test_ocr.py` -- the text side of the OCR pipeline, which is
/// the part that's testable without a real screenshot.
final class NotificationParsingTests: XCTestCase {

    private func parse(_ text: String) -> PurchaseTextParser.NotificationPurchase? {
        PurchaseTextParser.parseNotification(text, defaultCurrency: "USD")
    }

    func testChaseStyleAlert() throws {
        let result = try XCTUnwrap(
            parse("Chase Alert: You made a $52.13 transaction at TARGET T-1234 on your card ending in 1234")
        )
        XCTAssertEqual(result.amount, 52.13, accuracy: 0.001)
        XCTAssertEqual(result.currencyCode, "USD")
        XCTAssertEqual(try XCTUnwrap(result.merchant).contains("TARGET"), true)
    }

    func testForeignCurrencyAlert() throws {
        let result = try XCTUnwrap(parse("You spent £34.99 with NETFLIX.COM"))
        XCTAssertEqual(result.amount, 34.99, accuracy: 0.001)
        XCTAssertEqual(result.currencyCode, "GBP")
    }

    func testDashSeparatedMerchant() throws {
        let result = try XCTUnwrap(parse("New transaction: $9.99 - STARBUCKS"))
        XCTAssertEqual(result.amount, 9.99, accuracy: 0.001)
        XCTAssertEqual(result.merchant, "STARBUCKS")
    }

    func testNoAmountReturnsNil() {
        XCTAssertNil(parse("Your statement is ready to view"))
    }

    func testAmountWithoutMerchantStillParses() throws {
        let result = try XCTUnwrap(parse("New transaction: $9.99"))
        XCTAssertEqual(result.amount, 9.99, accuracy: 0.001)
        XCTAssertNil(result.merchant)
    }

    /// Filler words next to "at"/"to" are not merchants.
    func testStopWordIsNotAMerchant() throws {
        let result = try XCTUnwrap(parse("A $15.00 charge was posted to your account"))
        XCTAssertNotEqual(result.merchant?.lowercased(), "your")
    }

    /// A business suffix like "CO., LTD." must not truncate the merchant at
    /// its first period -- the whole name is the merchant, not just "CO".
    func testMerchantWithBusinessSuffixIsNotTruncated() throws {
        let result = try XCTUnwrap(
            parse("SoFi Credit Card 16m ago $94.60 spent at CO., LTD. TRINITY AI *PENDING")
        )
        XCTAssertEqual(result.amount, 94.60, accuracy: 0.001)
        let merchant = try XCTUnwrap(result.merchant)
        XCTAssertTrue(merchant.contains("TRINITY"), "expected the full name, got \"\(merchant)\"")
        XCTAssertNotEqual(merchant, "CO")
    }
}

/// The layout side of the OCR pipeline: screenshots where the merchant and the
/// amount are on separate lines, with no sentence tying them together.
final class ScreenshotLayoutTests: XCTestCase {

    private func parse(_ lines: [String]) -> PurchaseTextParser.NotificationPurchase? {
        PurchaseTextParser.parseScreenshot(lines: lines, defaultCurrency: "USD")
    }

    func testMerchantOnTheLineAboveTheAmount() throws {
        let result = try XCTUnwrap(parse(["Starbucks", "$5.75", "Today at 3:42 PM"]))
        XCTAssertEqual(result.amount, 5.75, accuracy: 0.001)
        XCTAssertEqual(result.merchant, "Starbucks")
    }

    func testBoilerplateBetweenMerchantAndAmountIsSkipped() throws {
        let result = try XCTUnwrap(
            parse(["Transaction details", "Trader Joe's", "Pending", "$34.10", "Card ending in 4242"])
        )
        XCTAssertEqual(result.amount, 34.10, accuracy: 0.001)
        XCTAssertEqual(result.merchant, "Trader Joe's")
    }

    /// Nothing above the amount but chrome, so the name below it is taken.
    func testMerchantOnTheLineBelowTheAmount() throws {
        let result = try XCTUnwrap(parse(["Amount", "$18.00", "CHIPOTLE 2841"]))
        XCTAssertEqual(result.amount, 18.00, accuracy: 0.001)
        XCTAssertEqual(result.merchant, "CHIPOTLE 2841")
    }

    /// A transaction row: Vision often reads the name and the right-aligned
    /// amount as one line.
    func testMerchantBesideTheAmountOnOneLine() throws {
        let result = try XCTUnwrap(parse(["Recent", "NETFLIX.COM   $15.49", "Sep 2"]))
        XCTAssertEqual(result.amount, 15.49, accuracy: 0.001)
        XCTAssertEqual(result.merchant, "NETFLIX.COM")
    }

    /// A date, a time, or a card mask next to the amount is not a merchant.
    func testDatesAndCardMasksAreNotMerchants() throws {
        let result = try XCTUnwrap(parse(["Aug 29, 2025", "$12.00", "•••• 4242"]))
        XCTAssertEqual(result.amount, 12.00, accuracy: 0.001)
        XCTAssertNil(result.merchant)
    }

    /// A wrapped bank alert still parses as a sentence, ignoring line breaks.
    func testWrappedSentenceStillUsesTheProsePattern() throws {
        let result = try XCTUnwrap(
            parse(["Chase", "You made a $52.13 transaction", "at TARGET T-1234", "16m ago"])
        )
        XCTAssertEqual(result.amount, 52.13, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.merchant).contains("TARGET"), true)
    }

    /// The bare number in "16m ago" must not win over the marked amount, and
    /// the merchant is found relative to the amount's real line.
    func testTimestampAheadOfTheAmountIsNotTheAmount() throws {
        let result = try XCTUnwrap(parse(["SoFi", "16m ago", "TRINITY AI", "$94.60"]))
        XCTAssertEqual(result.amount, 94.60, accuracy: 0.001)
        XCTAssertEqual(result.merchant, "TRINITY AI")
    }

    func testNoAmountAnywhereReturnsNil() {
        XCTAssertNil(parse(["Statement ready", "Tap to view"]))
    }

    func testEmptyLinesReturnNil() {
        XCTAssertNil(parse(["", "   "]))
    }
}

final class CategoryMatcherTests: XCTestCase {

    func testExactName() {
        XCTAssertEqual(CategoryMatcher.match("Food", in: categories), "Food")
    }

    func testAliasWithNoSharedCharacters() {
        XCTAssertEqual(CategoryMatcher.match("grub", in: categories), "Food")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(CategoryMatcher.match("TRANSPORT", in: categories), "Transport")
    }

    func testTypoStillMatches() {
        XCTAssertEqual(CategoryMatcher.match("transprot", in: categories), "Transport")
    }

    func testUnrelatedTextReturnsNil() {
        XCTAssertNil(CategoryMatcher.match("xyzzy", in: categories))
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(CategoryMatcher.match("", in: categories))
    }

    func testNoCategoriesReturnsNil() {
        XCTAssertNil(CategoryMatcher.match("food", in: []))
    }

    func testSimilarityBounds() {
        XCTAssertEqual(CategoryMatcher.similarity("food", "food"), 1.0)
        XCTAssertEqual(CategoryMatcher.similarity("", "food"), 0.0)
        XCTAssertLessThan(CategoryMatcher.similarity("food", "transport"), 0.5)
    }
}
