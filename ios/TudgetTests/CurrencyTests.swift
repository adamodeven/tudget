import XCTest
@testable import Tudget

/// Mirrors `tests/test_currency.py` on the Python side, so both
/// implementations are held to the same parsing behaviour.
final class CurrencyParserTests: XCTestCase {

    private func parse(_ text: String, default defaultCurrency: String = "USD")
        -> (amount: Double, currencyCode: String)? {
        CurrencyParser.parseAmountAndCurrency(in: text, defaultCurrency: defaultCurrency)
    }

    func testDollarSymbol() throws {
        let result = try XCTUnwrap(parse("CVS $8.50 health"))
        XCTAssertEqual(result.amount, 8.50, accuracy: 0.001)
        XCTAssertEqual(result.currencyCode, "USD")
    }

    func testEuroSymbolWithCommaDecimal() throws {
        let result = try XCTUnwrap(parse("€12,47 lunch"))
        XCTAssertEqual(result.amount, 12.47, accuracy: 0.001)
        XCTAssertEqual(result.currencyCode, "EUR")
    }

    func testTrailingIsoCode() throws {
        let result = try XCTUnwrap(parse("12.47 EUR coffee"))
        XCTAssertEqual(result.amount, 12.47, accuracy: 0.001)
        XCTAssertEqual(result.currencyCode, "EUR")
    }

    func testLeadingIsoCode() throws {
        let result = try XCTUnwrap(parse("EUR 12.47 coffee"))
        XCTAssertEqual(result.amount, 12.47, accuracy: 0.001)
        XCTAssertEqual(result.currencyCode, "EUR")
    }

    func testMultiCharacterSymbolIsNotShadowedByDollar() throws {
        let result = try XCTUnwrap(parse("HK$120 dinner"))
        XCTAssertEqual(result.amount, 120, accuracy: 0.001)
        XCTAssertEqual(result.currencyCode, "HKD")
    }

    func testBareNumberFallsBackToDefaultCurrency() throws {
        let result = try XCTUnwrap(parse("12 coffee going out", default: "GBP"))
        XCTAssertEqual(result.amount, 12, accuracy: 0.001)
        XCTAssertEqual(result.currencyCode, "GBP")
    }

    func testNoNumberReturnsNil() {
        XCTAssertNil(parse("no numbers here"))
    }

    func testThousandsSeparator() throws {
        let result = try XCTUnwrap(parse("$1,234.56 rent"))
        XCTAssertEqual(result.amount, 1234.56, accuracy: 0.001)
    }

    func testEuropeanThousandsAndDecimal() throws {
        let result = try XCTUnwrap(parse("€1.234,56 rent"))
        XCTAssertEqual(result.amount, 1234.56, accuracy: 0.001)
    }

    /// A three-letter run inside a word must not be read as a currency code.
    func testWordContainingCodeIsNotTreatedAsCurrency() throws {
        let result = try XCTUnwrap(parse("40 EUROPEAN adapters", default: "USD"))
        XCTAssertEqual(result.currencyCode, "USD")
    }

    func testParseNumberVariants() {
        XCTAssertEqual(CurrencyParser.parseNumber("1,234"), 1234)
        XCTAssertEqual(CurrencyParser.parseNumber("12,47"), 12.47)
        XCTAssertEqual(CurrencyParser.parseNumber("1.234,56"), 1234.56)
        XCTAssertEqual(CurrencyParser.parseNumber("1,234.56"), 1234.56)
        XCTAssertEqual(CurrencyParser.parseNumber("42"), 42)
        XCTAssertNil(CurrencyParser.parseNumber("abc"))
    }

    /// A bare number earlier in the text -- a date, a relative timestamp --
    /// must not shadow the real, currency-marked amount that follows it.
    func testMarkedAmountIsPreferredOverEarlierBareNumber() throws {
        let result = try XCTUnwrap(
            parse("NUS FOODCOURT NUS - ST Aug 29, 2026 $4.57")
        )
        XCTAssertEqual(result.amount, 4.57, accuracy: 0.001)
        XCTAssertEqual(result.currencyCode, "USD")
    }

    /// Same failure mode as the date case, but with a relative timestamp
    /// ("16m ago") ahead of the amount, as seen in a notification banner
    /// screenshot.
    func testMarkedAmountIsPreferredOverPrecedingDuration() throws {
        let result = try XCTUnwrap(
            parse("SoFi Credit Card 16m ago $94.60 spent at CO., LTD.")
        )
        XCTAssertEqual(result.amount, 94.60, accuracy: 0.001)
        XCTAssertEqual(result.currencyCode, "USD")
    }

    /// The reported range must cover the symbol too, or stripping the amount
    /// out leaves a stray "€" in the merchant name.
    func testRangeIncludesSymbol() throws {
        let text = "Cafe Luna €12,47"
        let found = try XCTUnwrap(
            CurrencyParser.findAmount(in: text, defaultCurrency: "USD")
        )
        let remainder = text.replacingCharacters(in: found.range, with: "")
            .trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(remainder, "Cafe Luna")
    }
}

final class CurrencyFormattingTests: XCTestCase {

    func testPrefixSymbols() {
        XCTAssertEqual(Currency.format(12.5, code: "USD"), "$12.50")
        XCTAssertEqual(Currency.format(12.5, code: "EUR"), "€12.50")
    }

    func testZeroDecimalCurrency() {
        XCTAssertEqual(Currency.format(1200, code: "JPY"), "¥1,200")
    }

    func testUnknownSymbolFallsBackToSuffixedCode() {
        XCTAssertEqual(Currency.format(12.5, code: "SEK"), "12.50 SEK")
    }

    func testCompactDropsTrailingZeroCents() {
        XCTAssertEqual(Currency.formatCompact(400, code: "USD"), "$400")
        XCTAssertEqual(Currency.formatCompact(12.47, code: "USD"), "$12.47")
    }

    func testPickerPutsDeviceCurrencyFirstWithoutDuplicating() {
        let codes = Currency.pickerCodes(deviceCode: "GBP")
        XCTAssertEqual(codes.first, "GBP")
        XCTAssertEqual(codes.filter { $0 == "GBP" }.count, 1)
        XCTAssertEqual(Set(codes).count, codes.count)
    }
}

final class FXFallbackTests: XCTestCase {

    func testSameCurrencyIsIdentity() {
        XCTAssertEqual(FXRateService.fallbackRate(from: "USD", to: "USD"), 1.0)
    }

    func testFallbackCrossRateIsPlausible() {
        // ~1.08 USD per EUR, so EUR->USD must be meaningfully above 1.
        let rate = FXRateService.fallbackRate(from: "EUR", to: "USD")
        XCTAssertGreaterThan(rate, 1.0)
        XCTAssertLessThan(rate, 2.0)
    }

    func testUnknownCurrencyDegradesToOneToOne() {
        XCTAssertEqual(FXRateService.fallbackRate(from: "XYZ", to: "USD"), 1.0)
    }
}
