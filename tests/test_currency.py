import currency


def test_find_amount_dollar_symbol():
    amount, code, start, end = currency.find_amount("CVS $8.50 health")
    assert amount == 8.50
    assert code == "USD"


def test_find_amount_euro_symbol_comma_decimal():
    amount, code, start, end = currency.find_amount("€12,47 lunch")
    assert amount == 12.47
    assert code == "EUR"


def test_find_amount_code_suffix():
    amount, code, start, end = currency.find_amount("12.47 EUR coffee")
    assert amount == 12.47
    assert code == "EUR"


def test_find_amount_code_prefix():
    amount, code, start, end = currency.find_amount("EUR 12.47 coffee")
    assert amount == 12.47
    assert code == "EUR"


def test_find_amount_bare_number_uses_default():
    amount, code, start, end = currency.find_amount("12 coffee going out", default_currency="GBP")
    assert amount == 12.0
    assert code == "GBP"


def test_find_amount_no_number_returns_none():
    assert currency.find_amount("no numbers here") is None


def test_find_amount_thousands_separator():
    amount, code, start, end = currency.find_amount("$1,234.56 rent")
    assert amount == 1234.56


def test_find_amount_european_thousands_and_decimal():
    amount, code, start, end = currency.find_amount("€1.234,56 rent")
    assert amount == 1234.56


def test_format_amount_prefix_symbol():
    assert currency.format_amount(12.5, "USD") == "$12.50"
    assert currency.format_amount(12.5, "EUR") == "€12.50"


def test_format_amount_zero_decimal_currency():
    assert currency.format_amount(1200, "JPY") == "¥1,200"


def test_format_amount_unknown_code_suffix():
    assert currency.format_amount(12.5, "SEK") == "12.50 SEK"


def test_convert_same_currency_is_noop():
    assert currency.convert(42.0, "USD", "USD") == 42.0


def test_get_rate_same_currency():
    assert currency.get_rate("EUR", "EUR") == 1.0
