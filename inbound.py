"""Channel-agnostic handling of inbound purchase messages (SMS/MMS via
Twilio, or iMessage via BlueBubbles -- see messaging.py).

Three ways a message becomes a transaction:

  - Categorization reply: the user is replying to a "reply with category"
    prompt for a specific transaction (db.get_pending_categorization
    decides this). We fuzzy-match their reply against the category list
    (plus a small synonym table, since rapidfuzz alone can't tell that
    "grub" means "Food" -- they share no characters).

  - Manual entry: an unprompted text like "CVS $8.50 health" or
    "12,47 EUR coffee going out". We pull an amount+currency out with
    currency.find_amount, then check the trailing word(s) of what's left
    against the category list.

  - Screenshot entry: a photo with no text, e.g. a screenshot of a bank
    push notification. We OCR it (ocr.py) to pull out a merchant/amount
    and treat it like a manual entry that's missing its category.
"""

from __future__ import annotations

import mimetypes
import re
import time
from datetime import datetime
from pathlib import Path

from rapidfuzz import fuzz, process

import budget
import currency
import db
import ocr

# Synonyms layered on top of whatever category names exist in Notion, so
# that casual replies ("grub", "eating", "drinks") map to the right
# category even though they don't share characters with its name.
CATEGORY_ALIASES: dict[str, list[str]] = {
    "food": ["food", "groceries", "grocery", "eating", "eat", "grub", "snacks", "lunch", "dinner", "breakfast"],
    "going out": ["going out", "dining out", "drinks", "bar", "bars", "fun", "entertainment", "social", "nightlife", "restaurant"],
    "transport": ["transport", "transportation", "uber", "lyft", "gas", "gasoline", "commute", "transit", "taxi", "cab", "parking"],
    "shopping": ["shopping", "shop", "clothes", "clothing", "retail", "amazon"],
    "subscriptions": ["subscriptions", "subscription", "subs", "streaming", "recurring", "membership"],
    "other": ["other", "misc", "miscellaneous"],
}


# ---------------------------------------------------------------------------
# Category matching
# ---------------------------------------------------------------------------

def match_category(text: str, categories: list[dict], threshold: int = 70, scorer=fuzz.WRatio) -> str | None:
    text = text.strip().lower()
    if not text or not categories:
        return None

    search_terms: list[tuple[str, str]] = []
    for cat in categories:
        name = cat["name"]
        search_terms.append((name.lower(), name))
        for alias in CATEGORY_ALIASES.get(name.lower(), []):
            search_terms.append((alias, name))

    result = process.extractOne(text, [t[0] for t in search_terms], scorer=scorer)
    if result is None:
        return None

    _, score, idx = result
    if score >= threshold:
        return search_terms[idx][1]
    return None


# ---------------------------------------------------------------------------
# Manual entry parsing
# ---------------------------------------------------------------------------

def parse_manual_entry(
    text: str, categories: list[dict], default_currency: str = "USD"
) -> tuple[str | None, float | None, str, str | None]:
    """Parses free text like 'Trader Joe's $34 groceries' or '12,47 EUR
    coffee going out' into (merchant, amount, currency_code, category).
    merchant/amount/category may be None; currency_code always falls back
    to default_currency."""
    text = text.strip()
    found = currency.find_amount(text, default_currency)

    if found:
        amount, currency_code, start, end = found
        remainder = text[:start] + " " + text[end:]
    else:
        amount, currency_code = None, default_currency
        remainder = text

    remainder = re.sub(r"\s+", " ", remainder).strip(" $€£¥")

    if not remainder:
        return None, amount, currency_code, None

    words = remainder.split(" ")
    category = None
    merchant_words = words

    # Check the last word, then the last two words, against the category
    # list. A high threshold on the full-string ratio (not WRatio, whose
    # partial matching would let "out" match "Going Out") avoids mistaking
    # part of the merchant name for a category.
    for n in (1, 2):
        if len(words) > n:
            candidate = " ".join(words[-n:])
            matched = match_category(candidate, categories, threshold=85, scorer=fuzz.ratio)
            if matched:
                category = matched
                merchant_words = words[:-n]
                break

    merchant = " ".join(merchant_words).strip(" ,.") or None
    return merchant, amount, currency_code, category


# ---------------------------------------------------------------------------
# Receipt storage
# ---------------------------------------------------------------------------

def save_receipt(content: bytes, content_type: str, transaction_id: int, receipts_dir: str) -> str:
    """Saves the raw receipt/screenshot image to disk and returns its
    filename (relative to receipts_dir)."""
    ext = mimetypes.guess_extension(content_type.split(";")[0].strip()) or ".jpg"
    if ext == ".jpe":
        ext = ".jpg"
    filename = f"{transaction_id}_{int(time.time())}{ext}"

    path = Path(receipts_dir)
    path.mkdir(parents=True, exist_ok=True)
    (path / filename).write_bytes(content)
    return filename


# ---------------------------------------------------------------------------
# Outbound message formatting
# ---------------------------------------------------------------------------

def format_new_transaction_message(
    card: str, merchant: str, amount: float, currency_code: str, categories: list[dict]
) -> str:
    amount_str = currency.format_amount(amount, currency_code)
    names = " / ".join(c["name"] for c in categories)
    return f"{card}: {merchant} {amount_str} — reply with category ({names}) and optionally attach a receipt photo"


def _category_prompt(categories: list[dict]) -> str:
    return " / ".join(c["name"] for c in categories)


def _insert_and_convert(
    *, merchant: str, amount: float, currency_code: str, card: str, category: str | None,
    source: str, default_currency: str,
) -> int:
    amount_default = currency.convert(amount, currency_code, default_currency)
    return db.insert_transaction(
        merchant=merchant,
        amount=amount,
        currency=currency_code,
        amount_default_currency=amount_default,
        card=card,
        category=category,
        timestamp=datetime.now().isoformat(),
        source=source,
    )


# ---------------------------------------------------------------------------
# Inbound message handling
# ---------------------------------------------------------------------------

def handle_incoming_message(
    from_id: str,
    body: str,
    media_bytes: bytes | None,
    media_content_type: str | None,
    categories: list[dict],
    receipts_dir: str,
    default_currency: str,
) -> tuple[str, dict | None]:
    """Processes an inbound text/photo and returns (reply_text, sync_info).

    sync_info, if not None, tells the caller which transaction needs to be
    synced to Notion in the background.
    """
    body = (body or "").strip()

    pending = db.get_pending_categorization(from_id)
    if pending:
        return _handle_categorization_reply(pending, body, media_bytes, media_content_type, categories, receipts_dir, default_currency)
    return _handle_manual_entry(from_id, body, media_bytes, media_content_type, categories, receipts_dir, default_currency)


def _handle_categorization_reply(
    pending: dict,
    body: str,
    media_bytes: bytes | None,
    media_content_type: str | None,
    categories: list[dict],
    receipts_dir: str,
    default_currency: str,
) -> tuple[str, dict | None]:
    category = match_category(body, categories)
    if category is None:
        return f"Didn't catch that — reply with one of: {_category_prompt(categories)}", None

    update_fields: dict = {"category": category}
    if media_bytes:
        update_fields["receipt_path"] = save_receipt(media_bytes, media_content_type, pending["transaction_id"], receipts_dir)

    db.update_transaction(pending["transaction_id"], **update_fields)
    db.delete_pending_categorization(pending["id"])

    reply = budget.format_budget_reply(category, categories, default_currency)
    return reply, {"transaction_id": pending["transaction_id"]}


def _handle_manual_entry(
    from_id: str,
    body: str,
    media_bytes: bytes | None,
    media_content_type: str | None,
    categories: list[dict],
    receipts_dir: str,
    default_currency: str,
) -> tuple[str, dict | None]:
    if not body:
        if media_bytes:
            return _handle_screenshot(from_id, media_bytes, media_content_type, categories, receipts_dir, default_currency)
        return (
            "Text me a merchant and amount, like 'CVS $8.50 health', "
            "or send a screenshot of a purchase notification.",
            None,
        )

    merchant, amount, currency_code, category = parse_manual_entry(body, categories, default_currency)

    if amount is None:
        return "Got the merchant, but what was the amount?", None
    if not merchant:
        return "Got the amount, but what was the merchant?", None

    transaction_id = _insert_and_convert(
        merchant=merchant, amount=amount, currency_code=currency_code, card="Manual",
        category=category, source="manual", default_currency=default_currency,
    )

    if media_bytes:
        receipt_path = save_receipt(media_bytes, media_content_type, transaction_id, receipts_dir)
        db.update_transaction(transaction_id, receipt_path=receipt_path)

    if category is None:
        db.create_pending_categorization(transaction_id, from_id)
        amount_str = currency.format_amount(amount, currency_code)
        return (
            f"Got it — {amount_str} at {merchant}. "
            f"Reply with a category ({_category_prompt(categories)}) and I'll log it.",
            None,
        )

    reply = budget.format_budget_reply(category, categories, default_currency)
    return reply, {"transaction_id": transaction_id}


def _handle_screenshot(
    from_id: str,
    media_bytes: bytes,
    media_content_type: str | None,
    categories: list[dict],
    receipts_dir: str,
    default_currency: str,
) -> tuple[str, dict | None]:
    parsed = ocr.extract_purchase_from_image(media_bytes, default_currency)
    if parsed is None:
        return "Got the screenshot, but I couldn't read an amount off it — what was the merchant and amount?", None

    merchant = parsed["merchant"] or "Unknown merchant"
    amount = parsed["amount"]
    currency_code = parsed["currency"]

    transaction_id = _insert_and_convert(
        merchant=merchant, amount=amount, currency_code=currency_code, card="Manual (screenshot)",
        category=None, source="screenshot", default_currency=default_currency,
    )
    receipt_path = save_receipt(media_bytes, media_content_type or "image/jpeg", transaction_id, receipts_dir)
    db.update_transaction(transaction_id, receipt_path=receipt_path)

    db.create_pending_categorization(transaction_id, from_id)
    amount_str = currency.format_amount(amount, currency_code)
    merchant_note = f" at {parsed['merchant']}" if parsed["merchant"] else " (couldn't read the merchant off it, though)"
    return (
        f"Got it from your screenshot — {amount_str}{merchant_note}. "
        f"Reply with a category ({_category_prompt(categories)}) and I'll log it.",
        None,
    )
