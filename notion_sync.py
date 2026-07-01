"""All writes/reads to the three Notion databases (Categories,
Transactions, Budget Summary).

Receipt photos are stored raw on local disk (see twilio_client.save_receipt)
and linked into the Transactions DB as an "external" file pointing at this
server's public URL (config.server.base_url, i.e. your ngrok URL). Notion
never receives the image bytes directly and nothing is parsed from it.
"""

from __future__ import annotations

import logging
import re
from datetime import datetime
from pathlib import Path

import yaml
from notion_client import Client
from notion_client.errors import APIResponseError

import db
from config import CONFIG_PATH, AppConfig

logger = logging.getLogger(__name__)


def get_notion_client(config: AppConfig) -> Client:
    return Client(auth=config.notion.api_key)


# ---------------------------------------------------------------------------
# Database auto-creation
# ---------------------------------------------------------------------------

def _db_exists(client: Client, db_id: str) -> bool:
    if not db_id:
        return False
    try:
        client.databases.retrieve(database_id=db_id)
        return True
    except APIResponseError:
        return False


def _create_db(client: Client, parent_page_id: str, title: str, properties: dict) -> str:
    response = client.databases.create(
        parent={"type": "page_id", "page_id": parent_page_id},
        title=[{"type": "text", "text": {"content": title}}],
        properties=properties,
    )
    return response["id"]


def _write_db_ids(config: AppConfig, path: Path = CONFIG_PATH) -> None:
    """Write the three DB IDs back into config.yaml in place."""
    with open(path) as f:
        content = f.read()

    updates = {
        "categories_db_id": config.notion.categories_db_id,
        "transactions_db_id": config.notion.transactions_db_id,
        "budget_summary_db_id": config.notion.budget_summary_db_id,
    }
    for key, value in updates.items():
        content = re.sub(
            rf'^(\s*{re.escape(key)}:\s*).*$',
            rf'\1"{value}"',
            content,
            flags=re.MULTILINE,
        )

    with open(path, "w") as f:
        f.write(content)


def ensure_databases(client: Client, config: AppConfig) -> None:
    """Creates any of the three Notion databases that don't already exist,
    then writes the resulting IDs back into config.yaml so future runs
    don't re-create them.

    Requires config.notion.parent_page_id to be set and the integration
    to have access to that page. If all three databases already exist this
    is a no-op.
    """
    need_categories = not _db_exists(client, config.notion.categories_db_id)
    need_transactions = not _db_exists(client, config.notion.transactions_db_id)
    need_summary = not _db_exists(client, config.notion.budget_summary_db_id)

    if not any([need_categories, need_transactions, need_summary]):
        return

    parent = config.notion.parent_page_id
    if not parent:
        missing = [
            name for name, needed in [
                ("categories_db_id", need_categories),
                ("transactions_db_id", need_transactions),
                ("budget_summary_db_id", need_summary),
            ] if needed
        ]
        raise RuntimeError(
            f"Notion database IDs are missing ({', '.join(missing)}) and "
            "notion.parent_page_id is not set. Add a parent_page_id in "
            "config.yaml so Tudget can create the databases automatically, "
            "or create the databases manually and paste their IDs in."
        )

    if need_categories:
        db_id = _create_db(client, parent, "Categories", {
            "Name": {"title": {}},
            "Monthly Limit": {"number": {"format": "number"}},
            "Emoji": {"rich_text": {}},
        })
        config.notion.categories_db_id = db_id
        logger.info("Created Notion Categories database: %s", db_id)

    if need_transactions:
        db_id = _create_db(client, parent, "Transactions", {
            "Merchant": {"title": {}},
            "Amount": {"number": {"format": "number"}},
            "Card": {"select": {"options": []}},
            "Category": {"select": {"options": []}},
            "Receipt": {"files": {}},
            "Timestamp": {"date": {}},
            "Reconciled": {"checkbox": {}},
        })
        config.notion.transactions_db_id = db_id
        logger.info("Created Notion Transactions database: %s", db_id)

    if need_summary:
        db_id = _create_db(client, parent, "Budget Summary", {
            "Category": {"title": {}},
            "Spent": {"number": {"format": "number"}},
            "Limit": {"number": {"format": "number"}},
            "Remaining": {"number": {"format": "number"}},
            "% Used": {"number": {"format": "percent"}},
        })
        config.notion.budget_summary_db_id = db_id
        logger.info("Created Notion Budget Summary database: %s", db_id)

    _write_db_ids(config)
    logger.info("Wrote Notion database IDs to config.yaml")


# ---------------------------------------------------------------------------
# Property helpers
# ---------------------------------------------------------------------------

def _get_title(prop: dict | None) -> str | None:
    if not prop or not prop.get("title"):
        return None
    text = "".join(t["plain_text"] for t in prop["title"])
    return text or None


def _get_rich_text(prop: dict | None) -> str | None:
    if not prop or not prop.get("rich_text"):
        return None
    text = "".join(t["plain_text"] for t in prop["rich_text"])
    return text or None


def _get_number(prop: dict | None) -> float | None:
    if not prop:
        return None
    return prop.get("number")


def _query_all(client: Client, db_id: str):
    cursor = None
    while True:
        kwargs = {"database_id": db_id, "page_size": 100}
        if cursor:
            kwargs["start_cursor"] = cursor
        response = client.databases.query(**kwargs)
        yield from response["results"]
        if not response.get("has_more"):
            break
        cursor = response.get("next_cursor")


def _fetch_pages_by_title(client: Client, db_id: str, title_property: str) -> dict[str, str]:
    """Maps title text -> page_id for every page in a database."""
    pages = {}
    for page in _query_all(client, db_id):
        name = _get_title(page["properties"].get(title_property))
        if name:
            pages[name] = page["id"]
    return pages


# ---------------------------------------------------------------------------
# Categories DB
# ---------------------------------------------------------------------------

def fetch_categories(client: Client, db_id: str) -> list[dict]:
    """Reads the Categories DB: name, monthly_limit, emoji, notion_page_id."""
    categories = []
    for page in _query_all(client, db_id):
        props = page["properties"]
        name = _get_title(props.get("Name"))
        limit = _get_number(props.get("Monthly Limit"))
        if name is None or limit is None:
            continue
        categories.append(
            {
                "name": name,
                "monthly_limit": limit,
                "emoji": _get_rich_text(props.get("Emoji")) or "",
                "notion_page_id": page["id"],
            }
        )
    return categories


def upsert_categories(client: Client, db_id: str, categories: list[dict]) -> None:
    """Creates or updates rows in the Categories DB.

    categories: list of {"name", "monthly_limit", "emoji"}. Used by
    setup_budget.py to write confirmed budget limits.
    """
    existing = _fetch_pages_by_title(client, db_id, "Name")

    for cat in categories:
        properties = {
            "Name": {"title": [{"text": {"content": cat["name"]}}]},
            "Monthly Limit": {"number": cat["monthly_limit"]},
            "Emoji": {"rich_text": [{"text": {"content": cat.get("emoji", "")}}]},
        }
        page_id = existing.get(cat["name"])
        if page_id:
            client.pages.update(page_id=page_id, properties=properties)
        else:
            client.pages.create(parent={"database_id": db_id}, properties=properties)


# ---------------------------------------------------------------------------
# Transactions DB
# ---------------------------------------------------------------------------

def _transaction_properties(txn: dict, receipt_url: str | None) -> dict:
    properties: dict = {
        "Merchant": {"title": [{"text": {"content": txn["merchant"]}}]},
        "Amount": {"number": txn["amount"]},
        "Card": {"select": {"name": txn["card"]}},
        "Timestamp": {"date": {"start": txn["timestamp"]}},
        "Reconciled": {"checkbox": bool(txn["reconciled"])},
    }
    if txn["category"]:
        properties["Category"] = {"select": {"name": txn["category"]}}
    if receipt_url:
        properties["Receipt"] = {
            "files": [
                {
                    "type": "external",
                    "name": txn["receipt_path"],
                    "external": {"url": receipt_url},
                }
            ]
        }
    return properties


def create_transaction_page(client: Client, db_id: str, txn: dict, receipt_url: str | None) -> str:
    page = client.pages.create(
        parent={"database_id": db_id},
        properties=_transaction_properties(txn, receipt_url),
    )
    return page["id"]


def update_transaction_page(client: Client, page_id: str, txn: dict, receipt_url: str | None) -> None:
    client.pages.update(page_id=page_id, properties=_transaction_properties(txn, receipt_url))


def sync_transaction(transaction_id: int, config: AppConfig) -> None:
    """Creates or updates a transaction's Notion page and rebuilds the
    Budget Summary DB. Runs as a FastAPI background task after every
    categorized transaction (automatic or manual)."""
    client = get_notion_client(config)
    txn = db.get_transaction(transaction_id)
    if txn is None:
        return

    receipt_url = None
    if txn["receipt_path"]:
        base_url = config.server.base_url.rstrip("/")
        receipt_url = f"{base_url}/receipts/{txn['receipt_path']}"

    if txn["notion_page_id"]:
        update_transaction_page(client, txn["notion_page_id"], txn, receipt_url)
    else:
        page_id = create_transaction_page(client, config.notion.transactions_db_id, txn, receipt_url)
        db.update_transaction(transaction_id, notion_page_id=page_id)

    categories = db.get_categories()
    rebuild_budget_summary(client, config.notion.budget_summary_db_id, categories)


# ---------------------------------------------------------------------------
# Budget Summary DB
# ---------------------------------------------------------------------------

def rebuild_budget_summary(client: Client, db_id: str, categories: list[dict]) -> None:
    """Rewrites one row per category: spent, limit, remaining, % used for
    the current month."""
    existing = _fetch_pages_by_title(client, db_id, "Category")
    now = datetime.now()

    for cat in categories:
        spent = db.get_category_spent(cat["name"], now.year, now.month)
        limit = cat["monthly_limit"]
        remaining = limit - spent
        pct_used = (spent / limit) if limit else 0.0

        properties = {
            "Category": {"title": [{"text": {"content": cat["name"]}}]},
            "Spent": {"number": round(spent, 2)},
            "Limit": {"number": round(limit, 2)},
            "Remaining": {"number": round(remaining, 2)},
            "% Used": {"number": round(pct_used, 4)},
        }

        page_id = existing.get(cat["name"])
        if page_id:
            client.pages.update(page_id=page_id, properties=properties)
        else:
            client.pages.create(parent={"database_id": db_id}, properties=properties)
