"""Per-bank parsers for push-notification text forwarded from the Android
relay device (see README's "Android relay device" section).

Push notification wording varies by bank and changes over time, so these
parsers are deliberately simple regex-based best guesses at the common
"$X.XX at MERCHANT" phrasing. If a parser returns None for a real
notification from a configured bank app, main.py logs the raw
package/title/text to data/unparsed_notifications.log -- use that to adjust
the AMOUNT_RE/MERCHANT_RE patterns (or add a bank-specific tweak) to match
what your bank's app actually sends.

Each parser takes (title, body) and returns either:
    {"merchant": str, "amount": float, "card": str}
or None if the notification doesn't look like a purchase transaction alert
(e.g. it's a login alert, marketing push, balance update, etc.).
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


def parse_chase(title: str, body: str) -> dict | None:
    text = f"{title}\n{body}"
    amount = _extract_amount(text)
    merchant = _extract_merchant(text)
    if amount is None or merchant is None:
        return None
    return {"merchant": merchant, "amount": amount, "card": "Chase Credit"}


def parse_sofi(title: str, body: str) -> dict | None:
    text = f"{title}\n{body}"
    amount = _extract_amount(text)
    merchant = _extract_merchant(text)
    if amount is None or merchant is None:
        return None
    card = "SoFi Credit" if re.search(r"credit", text, re.IGNORECASE) else "SoFi Debit"
    return {"merchant": merchant, "amount": amount, "card": card}


def parse_fidelity(title: str, body: str) -> dict | None:
    text = f"{title}\n{body}"
    amount = _extract_amount(text)
    merchant = _extract_merchant(text)
    if amount is None or merchant is None:
        return None
    return {"merchant": merchant, "amount": amount, "card": "Fidelity Debit"}


def parse_venmo(title: str, body: str) -> dict | None:
    text = f"{title}\n{body}"
    amount = _extract_amount(text)
    merchant = _extract_merchant(text)
    if amount is None or merchant is None:
        return None
    return {"merchant": merchant, "amount": amount, "card": "Venmo Credit"}


# Maps a notification.apps config value (bank key) to its parser.
BANK_PARSERS = {
    "chase": parse_chase,
    "sofi": parse_sofi,
    "fidelity": parse_fidelity,
    "venmo": parse_venmo,
}
