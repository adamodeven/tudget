import ocr


def test_extract_purchase_from_text_amount_and_merchant():
    text = "Chase Mobile app Alert: You made a $52.13 transaction at TARGET T-1234 on your card ending in 1234"
    result = ocr.extract_purchase_from_text(text)
    assert result is not None
    assert result["amount"] == 52.13
    assert result["currency"] == "USD"
    assert result["merchant"] is not None
    assert "TARGET" in result["merchant"]


def test_extract_purchase_from_text_foreign_currency():
    text = "You spent £34.99 with NETFLIX.COM"
    result = ocr.extract_purchase_from_text(text)
    assert result is not None
    assert result["amount"] == 34.99
    assert result["currency"] == "GBP"


def test_extract_purchase_from_text_no_amount_returns_none():
    assert ocr.extract_purchase_from_text("Your statement is ready to view") is None


def test_extract_purchase_from_text_no_merchant_still_returns_amount():
    result = ocr.extract_purchase_from_text("New transaction: $9.99")
    assert result is not None
    assert result["amount"] == 9.99
    assert result["merchant"] is None
