"""Two-way MMS: sends transaction alerts and handles inbound replies.

Inbound message handling has two modes (db.get_pending_categorization
decides which one applies):

  - Categorization reply: the user is replying to a "reply with category"
    prompt for a specific transaction. We fuzzy-match their reply against
    the Notion category list (plus a small synonym table, since rapidfuzz
    alone can't tell that "grub" means "Food" -- they share no characters).

  - Manual entry: an unprompted text like "CVS $8.50 health" or
    "$12 coffee going out". We pull the dollar amount out with a regex,
    then check the trailing word(s) of what's left against the category
    list -- if they match, that's the category and the rest is the
    merchant; otherwise the whole remainder is the merchant and we ask
    for a category like any other new transaction.
"""

from __future__ import annotations

import mimetypes
import re
import time
from datetime import datetime
from pathlib import Path

import requests
from rapidfuzz import fuzz, process
from twilio.rest import Client

import budget
import db
from config import AppConfig

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

AMOUNT_RE = re.compile(r"\$?\s*(\d+(?:\.\d{1,2})?)")


class TwilioClient:
    def __init__(self, config: AppConfig):
        self.client = Client(config.twilio.account_sid, config.twilio.auth_token)
        self.account_sid = config.twilio.account_sid
        self.auth_token = config.twilio.auth_token
        self.from_number = config.twilio.from_number

    def send_sms(self, to: str, body: str) -> None:
        self.client.messages.create(to=to, from_=self.from_number, body=body)

    def download_media(self, media_url: str) -> tuple[bytes, str]:
        resp = requests.get(media_url, auth=(self.account_sid, self.auth_token), timeout=30)
        resp.raise_for_status()
        content_type = resp.headers.get("Content-Type", "image/jpeg")
        return resp.content, content_type


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

def parse_manual_entry(text: str, categories: list[dict]) -> tuple[str | None, float | None, str | None]:
    """Parses free text like 'Trader Joe's $34 groceries' into
    (merchant, amount, category). Any of the three may be None."""
    text = text.strip()
    amount_match = AMOUNT_RE.search(text)
    amount = float(amount_match.group(1)) if amount_match else None

    if amount_match:
        remainder = text[: amount_match.start()] + " " + text[amount_match.end() :]
    else:
        remainder = text
    remainder = re.sub(r"\s+", " ", remainder).strip(" $")

    if not remainder:
        return None, amount, None

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
    return merchant, amount, category


# ---------------------------------------------------------------------------
# Receipt storage
# ---------------------------------------------------------------------------

def save_receipt(content: bytes, content_type: str, transaction_id: int, receipts_dir: str) -> str:
    """Saves the raw receipt image to disk and returns its filename
    (relative to receipts_dir)."""
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

def format_new_transaction_message(card: str, merchant: str, amount: float, categories: list[dict]) -> str:
    names = " / ".join(c["name"] for c in categories)
    return f"{card}: {merchant} ${amount:.2f} — reply with category ({names}) and optionally attach a receipt photo"


def _category_prompt(categories: list[dict]) -> str:
    return " / ".join(c["name"] for c in categories)


# ---------------------------------------------------------------------------
# Inbound message handling
# ---------------------------------------------------------------------------

def handle_incoming_message(
    from_number: str,
    body: str,
    media_url: str | None,
    categories: list[dict],
    twilio_client: TwilioClient,
    receipts_dir: str,
) -> tuple[str, dict | None]:
    """Processes an inbound SMS/MMS and returns (reply_text, sync_info).

    sync_info, if not None, tells main.py which transaction needs to be
    synced to Notion in the background.
    """
    body = (body or "").strip()

    media_bytes = None
    media_content_type = None
    if media_url:
        media_bytes, media_content_type = twilio_client.download_media(media_url)

    pending = db.get_pending_categorization(from_number)
    if pending:
        return _handle_categorization_reply(pending, body, media_bytes, media_content_type, categories, receipts_dir)
    return _handle_manual_entry(from_number, body, media_bytes, media_content_type, categories, receipts_dir)


def _handle_categorization_reply(
    pending: dict,
    body: str,
    media_bytes: bytes | None,
    media_content_type: str | None,
    categories: list[dict],
    receipts_dir: str,
) -> tuple[str, dict | None]:
    category = match_category(body, categories)
    if category is None:
        return f"Didn't catch that — reply with one of: {_category_prompt(categories)}", None

    update_fields: dict = {"category": category}
    if media_bytes:
        update_fields["receipt_path"] = save_receipt(media_bytes, media_content_type, pending["transaction_id"], receipts_dir)

    db.update_transaction(pending["transaction_id"], **update_fields)
    db.delete_pending_categorization(pending["id"])

    reply = budget.format_budget_reply(category, categories)
    return reply, {"transaction_id": pending["transaction_id"]}


def _handle_manual_entry(
    from_number: str,
    body: str,
    media_bytes: bytes | None,
    media_content_type: str | None,
    categories: list[dict],
    receipts_dir: str,
) -> tuple[str, dict | None]:
    if not body:
        if media_bytes:
            return "Got the receipt — what was the merchant and amount?", None
        return "Text me a merchant and amount, like 'CVS $8.50 health'.", None

    merchant, amount, category = parse_manual_entry(body, categories)

    if amount is None:
        return "Got the merchant, but what was the amount?", None
    if not merchant:
        return "Got the amount, but what was the merchant?", None

    transaction_id = db.insert_transaction(
        merchant=merchant,
        amount=amount,
        card="Manual",
        category=category,
        timestamp=datetime.now().isoformat(),
        source="manual",
    )

    if media_bytes:
        receipt_path = save_receipt(media_bytes, media_content_type, transaction_id, receipts_dir)
        db.update_transaction(transaction_id, receipt_path=receipt_path)

    if category is None:
        db.create_pending_categorization(transaction_id, from_number)
        return (
            f"Got it — ${amount:.2f} at {merchant}. "
            f"Reply with a category ({_category_prompt(categories)}) and I'll log it.",
            None,
        )

    reply = budget.format_budget_reply(category, categories)
    return reply, {"transaction_id": transaction_id}
