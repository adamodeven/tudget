"""Per-bank parsers for transaction-alert emails.

Bank alert email wording varies by bank and changes over time, so these
parsers are deliberately simple regex-based best guesses at the common
"$X.XX at MERCHANT" phrasing. If a parser returns None for a real alert
email, gmail_poller logs the raw subject/body to data/unparsed_emails.log
so the patterns below can be tuned to match what your bank actually sends.

Each parser takes (subject, body, default_currency) and returns either:
    {"merchant": str, "amount": float, "currency": str, "card": str}
or None if the email doesn't look like a purchase transaction alert
(e.g. it's a login alert, statement notice, low-balance warning, etc.).
"""

from __future__ import annotations

import re

import currency

# Looks for "at/with/to/from MERCHANT" stopping at common trailing words,
# punctuation, or end of line.
MERCHANT_RE = re.compile(
    r"(?:at|with|to|from)\s+"
    r"([A-Z0-9][\w &'\.\-#]{1,40}?)"
    r"(?=\s+(?:on|for|using|ending|with|\$)|[,\.\n]|$)",
    re.IGNORECASE,
)


def _extract_amount_currency(text: str, default_currency: str) -> tuple[float, str] | None:
    return currency.parse_amount_currency(text, default_currency)


def _extract_merchant(text: str) -> str | None:
    match = MERCHANT_RE.search(text)
    if not match:
        return None
    merchant = re.sub(r"\s+", " ", match.group(1)).strip(" .,-")
    return merchant or None


def parse_chase(subject: str, body: str, default_currency: str = "USD") -> dict | None:
    text = f"{subject}\n{body}"
    amount_currency = _extract_amount_currency(text, default_currency)
    merchant = _extract_merchant(text)
    if amount_currency is None or merchant is None:
        return None
    amount, code = amount_currency
    return {"merchant": merchant, "amount": amount, "currency": code, "card": "Chase Credit"}


def parse_sofi(subject: str, body: str, default_currency: str = "USD") -> dict | None:
    text = f"{subject}\n{body}"
    amount_currency = _extract_amount_currency(text, default_currency)
    merchant = _extract_merchant(text)
    if amount_currency is None or merchant is None:
        return None
    amount, code = amount_currency
    card = "SoFi Credit" if re.search(r"credit card", text, re.IGNORECASE) else "SoFi Debit"
    return {"merchant": merchant, "amount": amount, "currency": code, "card": card}


def parse_fidelity(subject: str, body: str, default_currency: str = "USD") -> dict | None:
    text = f"{subject}\n{body}"
    amount_currency = _extract_amount_currency(text, default_currency)
    merchant = _extract_merchant(text)
    if amount_currency is None or merchant is None:
        return None
    amount, code = amount_currency
    return {"merchant": merchant, "amount": amount, "currency": code, "card": "Fidelity Debit"}


def parse_venmo(subject: str, body: str, default_currency: str = "USD") -> dict | None:
    text = f"{subject}\n{body}"
    amount_currency = _extract_amount_currency(text, default_currency)
    merchant = _extract_merchant(text)
    if amount_currency is None or merchant is None:
        return None
    amount, code = amount_currency
    return {"merchant": merchant, "amount": amount, "currency": code, "card": "Venmo Credit"}


# Maps a bank_senders config key to its parser.
BANK_PARSERS = {
    "chase": parse_chase,
    "sofi": parse_sofi,
    "fidelity": parse_fidelity,
    "venmo": parse_venmo,
}
