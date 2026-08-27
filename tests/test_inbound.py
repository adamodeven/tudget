import inbound

CATEGORIES = [
    {"name": "Food", "monthly_limit": 400},
    {"name": "Going Out", "monthly_limit": 200},
    {"name": "Transport", "monthly_limit": 100},
]


def test_parse_manual_entry_dollar_amount_no_matching_category():
    merchant, amount, code, category = inbound.parse_manual_entry("CVS $8.50 health", CATEGORIES)
    assert merchant == "CVS health"  # "health" isn't a known category/alias, so it stays part of the merchant
    assert amount == 8.50
    assert code == "USD"
    assert category is None


def test_parse_manual_entry_leading_amount():
    merchant, amount, code, category = inbound.parse_manual_entry("$12 coffee going out", CATEGORIES)
    assert amount == 12.0
    assert category == "Going Out"
    assert merchant == "coffee"


def test_parse_manual_entry_foreign_currency():
    merchant, amount, code, category = inbound.parse_manual_entry("Cafe Luna €12,47 food", CATEGORIES)
    assert merchant == "Cafe Luna"
    assert amount == 12.47
    assert code == "EUR"
    assert category == "Food"


def test_parse_manual_entry_no_amount():
    merchant, amount, code, category = inbound.parse_manual_entry("Trader Joe's groceries", CATEGORIES)
    assert amount is None


def test_match_category_alias():
    assert inbound.match_category("grub", CATEGORIES) == "Food"


def test_match_category_none_for_unrelated_text():
    assert inbound.match_category("xyzzy", CATEGORIES) is None
