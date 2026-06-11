"""All SQLite operations for Tudget.

SQLite is the source of truth: every transaction, category limit, and
pending categorization lives here first. Notion is synced from this data,
not the other way around (except for the Categories DB, which the user
edits directly in Notion and which we read back periodically).
"""

from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

from rapidfuzz import fuzz

DB_PATH = Path(__file__).parent / "data" / "tudget.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS categories (
    name TEXT PRIMARY KEY,
    monthly_limit REAL NOT NULL,
    emoji TEXT NOT NULL DEFAULT '',
    notion_page_id TEXT,
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS transactions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    merchant TEXT NOT NULL,
    amount REAL NOT NULL,
    card TEXT NOT NULL,
    category TEXT,
    receipt_path TEXT,
    timestamp TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'notification',
    reconciled INTEGER NOT NULL DEFAULT 0,
    notion_page_id TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS pending_categorizations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    transaction_id INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
    phone_number TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS processed_notifications (
    notification_hash TEXT PRIMARY KEY,
    processed_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_transactions_timestamp ON transactions(timestamp);
CREATE INDEX IF NOT EXISTS idx_transactions_category ON transactions(category);
CREATE INDEX IF NOT EXISTS idx_pending_phone ON pending_categorizations(phone_number);
"""


@contextmanager
def get_connection() -> Iterator[sqlite3.Connection]:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db() -> None:
    with get_connection() as conn:
        conn.executescript(SCHEMA)


# ---------------------------------------------------------------------------
# Categories
# ---------------------------------------------------------------------------

def replace_categories(categories: list[dict[str, Any]]) -> None:
    """Full sync of the categories table from Notion.

    Categories removed from Notion are dropped here too, so budget totals
    don't include stale categories.
    """
    with get_connection() as conn:
        names = [c["name"] for c in categories]
        if names:
            placeholders = ",".join("?" for _ in names)
            conn.execute(
                f"DELETE FROM categories WHERE name NOT IN ({placeholders})",
                names,
            )
        else:
            conn.execute("DELETE FROM categories")

        for cat in categories:
            conn.execute(
                """
                INSERT INTO categories (name, monthly_limit, emoji, notion_page_id, updated_at)
                VALUES (?, ?, ?, ?, datetime('now'))
                ON CONFLICT(name) DO UPDATE SET
                    monthly_limit = excluded.monthly_limit,
                    emoji = excluded.emoji,
                    notion_page_id = excluded.notion_page_id,
                    updated_at = datetime('now')
                """,
                (cat["name"], cat["monthly_limit"], cat.get("emoji", ""), cat.get("notion_page_id")),
            )


def get_categories() -> list[dict[str, Any]]:
    with get_connection() as conn:
        rows = conn.execute("SELECT * FROM categories ORDER BY name").fetchall()
        return [dict(row) for row in rows]


def get_category(name: str) -> dict[str, Any] | None:
    with get_connection() as conn:
        row = conn.execute("SELECT * FROM categories WHERE name = ?", (name,)).fetchone()
        return dict(row) if row else None


# ---------------------------------------------------------------------------
# Processed notifications (dedupe for the /notification webhook)
# ---------------------------------------------------------------------------

def is_notification_processed(notification_hash: str) -> bool:
    with get_connection() as conn:
        row = conn.execute(
            "SELECT 1 FROM processed_notifications WHERE notification_hash = ?", (notification_hash,)
        ).fetchone()
        return row is not None


def mark_notification_processed(notification_hash: str) -> None:
    with get_connection() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO processed_notifications (notification_hash) VALUES (?)",
            (notification_hash,),
        )


# ---------------------------------------------------------------------------
# Transactions
# ---------------------------------------------------------------------------

def insert_transaction(
    merchant: str,
    amount: float,
    card: str,
    timestamp: str,
    category: str | None = None,
    receipt_path: str | None = None,
    source: str = "notification",
    reconciled: bool = False,
    notion_page_id: str | None = None,
) -> int:
    with get_connection() as conn:
        cur = conn.execute(
            """
            INSERT INTO transactions
                (merchant, amount, card, category, receipt_path, timestamp, source, reconciled, notion_page_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (merchant, amount, card, category, receipt_path, timestamp, source, int(reconciled), notion_page_id),
        )
        return cur.lastrowid


def get_transaction(transaction_id: int) -> dict[str, Any] | None:
    with get_connection() as conn:
        row = conn.execute(
            "SELECT * FROM transactions WHERE id = ?", (transaction_id,)
        ).fetchone()
        return dict(row) if row else None


def update_transaction(transaction_id: int, **fields: Any) -> None:
    if not fields:
        return
    columns = ", ".join(f"{key} = ?" for key in fields)
    values = list(fields.values()) + [transaction_id]
    with get_connection() as conn:
        conn.execute(f"UPDATE transactions SET {columns} WHERE id = ?", values)


def get_category_spent(category: str, year: int, month: int) -> float:
    month_str = f"{year:04d}-{month:02d}"
    with get_connection() as conn:
        row = conn.execute(
            """
            SELECT COALESCE(SUM(amount), 0) AS total
            FROM transactions
            WHERE category = ? AND strftime('%Y-%m', timestamp) = ?
            """,
            (category, month_str),
        ).fetchone()
        return float(row["total"])


def get_month_total_spent(year: int, month: int) -> float:
    month_str = f"{year:04d}-{month:02d}"
    with get_connection() as conn:
        row = conn.execute(
            """
            SELECT COALESCE(SUM(amount), 0) AS total
            FROM transactions
            WHERE category IS NOT NULL AND strftime('%Y-%m', timestamp) = ?
            """,
            (month_str,),
        ).fetchone()
        return float(row["total"])


def get_unreconciled_transactions(start_iso: str, end_iso: str) -> list[dict[str, Any]]:
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT * FROM transactions
            WHERE reconciled = 0 AND timestamp BETWEEN ? AND ?
            """,
            (start_iso, end_iso),
        ).fetchall()
        return [dict(row) for row in rows]


def mark_reconciled(transaction_id: int) -> None:
    update_transaction(transaction_id, reconciled=1)


def find_matching_transaction(amount: float, merchant: str, date_str: str) -> dict[str, Any] | None:
    """Find a SQLite transaction matching a Plaid transaction.

    Matches on amount (within a cent) and date (+/- 1 day), then picks the
    best merchant fuzzy match above a threshold. Used by the nightly
    reconciliation job.
    """
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT * FROM transactions
            WHERE ABS(amount - ?) < 0.01
              AND date(timestamp) BETWEEN date(?, '-1 day') AND date(?, '+1 day')
            """,
            (amount, date_str, date_str),
        ).fetchall()

    best_row = None
    best_score = 0.0
    for row in rows:
        score = fuzz.WRatio(merchant.lower(), row["merchant"].lower())
        if score > best_score:
            best_score = score
            best_row = row

    if best_row is not None and best_score >= 70:
        return dict(best_row)
    return None


# ---------------------------------------------------------------------------
# Pending categorizations
# ---------------------------------------------------------------------------

def create_pending_categorization(transaction_id: int, phone_number: str) -> int:
    with get_connection() as conn:
        cur = conn.execute(
            "INSERT INTO pending_categorizations (transaction_id, phone_number) VALUES (?, ?)",
            (transaction_id, phone_number),
        )
        return cur.lastrowid


def get_pending_categorization(phone_number: str) -> dict[str, Any] | None:
    """Return the oldest pending categorization for this phone number, if any."""
    with get_connection() as conn:
        row = conn.execute(
            """
            SELECT * FROM pending_categorizations
            WHERE phone_number = ?
            ORDER BY created_at ASC
            LIMIT 1
            """,
            (phone_number,),
        ).fetchone()
        return dict(row) if row else None


def delete_pending_categorization(pending_id: int) -> None:
    with get_connection() as conn:
        conn.execute("DELETE FROM pending_categorizations WHERE id = ?", (pending_id,))
