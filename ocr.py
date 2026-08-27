"""Extracts a purchase (merchant, amount, currency) from a screenshot of a
bank/payment-app push notification.

This is the manual-submission alternative to letting the phone's OS hand
notifications straight to Tudget (that's the future Android-side
automation) -- for now, screenshotting a lock-screen or in-app purchase
alert and sending it in as a photo is the fastest way to log a purchase
without typing it out by hand.

Requires the `tesseract` binary to be installed on the host (see README) --
pytesseract just shells out to it.
"""

from __future__ import annotations

import io
import logging
import re

import pytesseract
from PIL import Image

import currency

logger = logging.getLogger(__name__)

# Looks for "at/with/to/from MERCHANT", the common phrasing in bank and
# payment-app purchase alerts ("You made a $12.47 purchase at TARGET").
_MERCHANT_PATTERNS = [
    re.compile(
        r"(?:at|with|to|from)\s+([A-Z0-9][\w &'\.\-#]{1,40}?)"
        r"(?=\s+(?:on|for|using|ending|with)|[,\.\n]|$)",
        re.IGNORECASE,
    ),
    # "New transaction: $12.47 - STARBUCKS" / "Card ending 1234: $9.99 NETFLIX.COM"
    re.compile(r"[:\-]\s*([A-Z][\w &'\.\-#]{2,40})\s*$"),
]


def extract_text(image_bytes: bytes) -> str:
    image = Image.open(io.BytesIO(image_bytes))
    return pytesseract.image_to_string(image)


def _extract_merchant(text: str) -> str | None:
    for pattern in _MERCHANT_PATTERNS:
        match = pattern.search(text)
        if match:
            merchant = re.sub(r"\s+", " ", match.group(1)).strip(" .,-")
            if merchant:
                return merchant
    return None


def extract_purchase_from_text(text: str, default_currency: str = "USD") -> dict | None:
    """Parses OCR'd (or any) notification text into
    {"merchant", "amount", "currency", "raw_text"}. Returns None if no
    amount could be found at all -- amount is the only field this refuses
    to guess at, since without it there's nothing to log."""
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return None

    parsed = currency.parse_amount_currency(text, default_currency)
    if parsed is None:
        return None
    amount, currency_code = parsed

    return {
        "merchant": _extract_merchant(text),
        "amount": amount,
        "currency": currency_code,
        "raw_text": text,
    }


def extract_purchase_from_image(image_bytes: bytes, default_currency: str = "USD") -> dict | None:
    try:
        text = extract_text(image_bytes)
    except Exception:
        logger.exception("OCR failed")
        return None
    return extract_purchase_from_text(text, default_currency)
