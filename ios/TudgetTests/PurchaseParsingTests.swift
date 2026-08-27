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
