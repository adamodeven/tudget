"""Currency parsing, formatting, and conversion.

Purchases can come in any currency (a manual text, a bank email, or an
OCR'd screenshot). Amounts are always stored in their original currency;
budget totals are converted to the configured default currency using live
FX rates (cached in memory, with a static fallback table for when the rate
API is unreachable).
"""

from __future__ import annotations

import logging
import re
import time

import requests

logger = logging.getLogger(__name__)

# Symbol -> ISO 4217 code. Longer/more specific symbols (e.g. "HK$") are
# tried before shorter ones (e.g. "$") so they aren't shadowed.
PREFIX_SYMBOLS: dict[str, str] = {
    "US$": "USD", "C$": "CAD", "CA$": "CAD", "A$": "AUD", "AU$": "AUD",
    "NZ$": "NZD", "HK$": "HKD", "S$": "SGD", "R$": "BRL",
    "$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR",
    "₩": "KRW", "₺": "TRY", "₽": "RUB", "₴": "UAH", "₫": "VND",
    "฿": "THB", "₱": "PHP",
}

KNOWN_CODES: set[str] = {
    "USD", "EUR", "GBP", "JPY", "INR", "KRW", "TRY", "RUB", "BRL", "UAH",
    "VND", "THB", "PHP", "SEK", "NOK", "DKK", "PLN", "CHF", "CAD", "AUD",
    "NZD", "HKD", "SGD", "MXN", "ZAR", "CNY", "AED", "ILS", "CZK", "HUF",
}

# Currencies whose smallest unit isn't a hundredth (no decimal places shown).
ZERO_DECIMAL_CURRENCIES: set[str] = {"JPY", "KRW", "VND", "HUF"}

# Codes that conventionally display with a leading symbol rather than a
# trailing "12.47 XYZ" code.
DISPLAY_SYMBOL: dict[str, str] = {
    "USD": "$", "CAD": "$", "AUD": "$", "NZD": "$", "HKD": "$", "SGD": "$",
    "EUR": "€", "GBP": "£", "JPY": "¥", "CNY": "¥", "INR": "₹", "KRW": "₩",
    "BRL": "R$",
}

_SYMBOLS_BY_LEN = sorted(PREFIX_SYMBOLS, key=len, reverse=True)
_SYMBOL_PATTERN = "|".join(re.escape(s) for s in _SYMBOLS_BY_LEN)
_NUMBER_PATTERN = r"\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?"

AMOUNT_RE = re.compile(
    rf"(?:(?P<symbol>{_SYMBOL_PATTERN})\s?(?P<amt1>{_NUMBER_PATTERN})"
    rf"|(?P<code_pre>[A-Z]{{3}})\s?(?P<amt2>{_NUMBER_PATTERN})"
    rf"|(?P<amt3>{_NUMBER_PATTERN})\s?(?P<code_post>[A-Z]{{3}})"
    rf"|(?P<amt4>{_NUMBER_PATTERN}))"
)

FX_API_URL = "https://api.frankfurter.app/latest"
_CACHE_TTL_SECONDS = 3600
_rate_cache: dict[tuple[str, str], tuple[float, float]] = {}

# Approximate USD rates used only if the FX API is unreachable.
_FALLBACK_RATES_TO_USD: dict[str, float] = {
    "USD": 1.0, "EUR": 1.08, "GBP": 1.27, "JPY": 0.0064, "INR": 0.012,
    "KRW": 0.00072, "TRY": 0.029, "RUB": 0.011, "BRL": 0.17, "UAH": 0.024,
    "VND": 0.00004, "THB": 0.028, "PHP": 0.017, "SEK": 0.095, "NOK": 0.091,
    "DKK": 0.145, "PLN": 0.25, "CHF": 1.11, "CAD": 0.73, "AUD": 0.66,
    "NZD": 0.60, "HKD": 0.128, "SGD": 0.74, "MXN": 0.049, "ZAR": 0.054,
    "CNY": 0.14, "AED": 0.27, "ILS": 0.27, "CZK": 0.043, "HUF": 0.0027,
}


def _parse_number(raw: str) -> float:
    """Parses a locale-ambiguous number string ("1,234", "12,47", "1.234,56",
    "1,234.56") into a float, guessing the decimal separator from context."""
    raw = raw.strip()
    has_comma = "," in raw
    has_dot = "." in raw

    if has_comma and has_dot:
        if raw.rfind(",") > raw.rfind("."):
            raw = raw.replace(".", "").replace(",", ".")
        else:
            raw = raw.replace(",", "")
    elif has_comma:
        groups = raw.split(",")
        if len(groups[-1]) <= 2:
            raw = raw[: raw.rfind(",")].replace(",", "") + "." + groups[-1]
        else:
            raw = raw.replace(",", "")

    return float(raw)


def find_amount(text: str, default_currency: str = "USD") -> tuple[float, str, int, int] | None:
    """Finds the first amount in free text. Returns (amount, currency_code,
    span_start, span_end), or None if no number is found."""
    for match in AMOUNT_RE.finditer(text):
        if match.group("symbol"):
            code = PREFIX_SYMBOLS[match.group("symbol")]
            return _parse_number(match.group("amt1")), code, match.start(), match.end()
        if match.group("code_pre") and match.group("code_pre") in KNOWN_CODES:
            return _parse_number(match.group("amt2")), match.group("code_pre"), match.start(), match.end()
        if match.group("code_post") and match.group("code_post") in KNOWN_CODES:
            return _parse_number(match.group("amt3")), match.group("code_post"), match.start(), match.end()
        if match.group("amt4"):
            return _parse_number(match.group("amt4")), default_currency, match.start(), match.end()
    return None


def parse_amount_currency(text: str, default_currency: str = "USD") -> tuple[float, str] | None:
    found = find_amount(text, default_currency)
    return (found[0], found[1]) if found else None


def format_amount(amount: float, currency_code: str) -> str:
    decimals = 0 if currency_code in ZERO_DECIMAL_CURRENCIES else 2
    formatted = f"{amount:,.{decimals}f}"
    symbol = DISPLAY_SYMBOL.get(currency_code)
    if symbol:
        return f"{symbol}{formatted}"
    return f"{formatted} {currency_code}"


def get_rate(from_code: str, to_code: str) -> float:
    """Live exchange rate for 1 unit of from_code in to_code, cached for
    _CACHE_TTL_SECONDS. Falls back to an approximate static table if the
    rate API can't be reached."""
    if from_code == to_code:
        return 1.0

    key = (from_code, to_code)
    now = time.time()
    cached = _rate_cache.get(key)
    if cached and now - cached[1] < _CACHE_TTL_SECONDS:
        return cached[0]

    try:
        resp = requests.get(FX_API_URL, params={"from": from_code, "to": to_code}, timeout=5)
        resp.raise_for_status()
        rate = float(resp.json()["rates"][to_code])
        _rate_cache[key] = (rate, now)
        return rate
    except Exception:
        logger.warning("FX rate lookup failed for %s->%s, using fallback table", from_code, to_code)
        from_usd = _FALLBACK_RATES_TO_USD.get(from_code)
        to_usd = _FALLBACK_RATES_TO_USD.get(to_code)
        if from_usd and to_usd:
            return from_usd / to_usd
        logger.warning("No fallback rate for %s->%s, treating as 1:1", from_code, to_code)
        return 1.0


def convert(amount: float, from_code: str, to_code: str) -> float:
    if from_code == to_code:
        return amount
    return amount * get_rate(from_code, to_code)
