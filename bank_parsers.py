"""Per-bank parsers for transaction-alert emails.

Bank alert email wording varies by bank and changes over time, so these
parsers are deliberately simple regex-based best guesses at the common
"$X.XX at MERCHANT" phrasing. If a parser returns None for a real alert
email, gmail_poller logs the raw subject/body to data/unparsed_emails.log
so the patterns below can be tuned to match what your bank actually sends.

Each parser takes (subject, body) and returns either:
    {"merchant": str, "amount": float, "card": str}
or None if the email doesn't look like a purchase transaction alert
(e.g. it's a login alert, statement notice, low-balance warning, etc.).
"""

from __future__ import annotations

import re

AMOUNT_RE = re.compile(r"\$\s?([\d,]+\.\d{2})")

# Looks for "at/with/to/from MERCHANT" stopping at common trailing words,
# punctuation, or end of line.
MERCHANT_RE = re.compile(
    r"(?:at|with|to|from)\s+"
    r"([A-Z0-9][\w &'\.\-#]{1,40}?)"
    r"(?=\s+(?:on|for|using|ending|with|\$)|[,\.\n]|$)",
    re.IGNORECASE,
)


def _extract_amount(text: str) -> float | None:
    match = AMOUNT_RE.search(text)
    if not match:
        return None
    return float(match.group(1).replace(",", ""))


def _extract_merchant(text: str) -> str | None:
    match = MERCHANT_RE.search(text)
    if not match:
        return None
    merchant = re.sub(r"\s+", " ", match.group(1)).strip(" .,-")
    return merchant or None


def parse_chase(subject: str, body: str) -> dict | None:
    text = f"{subject}\n{body}"
    amount = _extract_amount(text)
    merchant = _extract_merchant(text)
    if amount is None or merchant is None:
        return None
    return {"merchant": merchant, "amount": amount, "card": "Chase Credit"}


def parse_sofi(subject: str, body: str) -> dict | None:
    text = f"{subject}\n{body}"
    amount = _extract_amount(text)
    merchant = _extract_merchant(text)
    if amount is None or merchant is None:
        return None
    card = "SoFi Credit" if re.search(r"credit card", text, re.IGNORECASE) else "SoFi Debit"
    return {"merchant": merchant, "amount": amount, "card": card}


def parse_fidelity(subject: str, body: str) -> dict | None:
    text = f"{subject}\n{body}"
    amount = _extract_amount(text)
    merchant = _extract_merchant(text)
    if amount is None or merchant is None:
        return None
    return {"merchant": merchant, "amount": amount, "card": "Fidelity Debit"}


def parse_venmo(subject: str, body: str) -> dict | None:
    text = f"{subject}\n{body}"
    amount = _extract_amount(text)
    merchant = _extract_merchant(text)
    if amount is None or merchant is None:
        return None
    return {"merchant": merchant, "amount": amount, "card": "Venmo Credit"}


# Maps a bank_senders config key to its parser.
BANK_PARSERS = {
    "chase": parse_chase,
    "sofi": parse_sofi,
    "fidelity": parse_fidelity,
    "venmo": parse_venmo,
}
