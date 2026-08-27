"""SQLite storage for intercepted purchase notifications.

One table. The server's whole job is to hold a notification until the phone
asks for it, so there's nothing here about budgets, categories, or limits --
those live in the app, which is the source of truth.
"""

from __future__ import annotations

import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

DB_PATH = Path(__file__).parent / "data" / "tudget-ingest.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS incoming_transactions (
    uuid TEXT PRIMARY KEY,
    merchant TEXT NOT NULL DEFAULT '',
    amount REAL NOT NULL,
    currency_code TEXT NOT NULL DEFAULT 'USD',
    raw_text TEXT,
    source_app TEXT,
    occurred_at TEXT NOT NULL,
    received_at TEXT NOT NULL,
    claimed INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_incoming_claimed
    ON incoming_transactions(claimed, occurred_at);
"""


@contextmanager
def get_connection() -> Iterator[sqlite3.Connection]:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db() -> None:
    with get_connection() as conn:
        conn.executescript(SCHEMA)


def upsert_transaction(
    uuid: str,
    merchant: str,
    amount: float,
    currency_code: str,
    raw_text: str | None,
    source_app: str | None,
    occurred_at: str,
) -> bool:
    """Insert, or update if this uuid has been sent before.

    Returns True when the row is new. The client keeps the uuid stable across
    retries, so a dropped response never turns into a duplicate purchase.
    """
    received_at = datetime.now(timezone.utc).isoformat()
    with get_connection() as conn:
        existing = conn.execute(
            "SELECT 1 FROM incoming_transactions WHERE uuid = ?", (uuid,)
        ).fetchone()

        conn.execute(
            """
            INSERT INTO incoming_transactions
                (uuid, merchant, amount, currency_code, raw_text, source_app,
                 occurred_at, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(uuid) DO UPDATE SET
                merchant = excluded.merchant,
                amount = excluded.amount,
                currency_code = excluded.currency_code,
                raw_text = excluded.raw_text,
                source_app = excluded.source_app,
                occurred_at = excluded.occurred_at
            """,
            (uuid, merchant, amount, currency_code, raw_text, source_app,
             occurred_at, received_at),
        )
        return existing is None


def list_transactions(include_claimed: bool = False) -> list[dict[str, Any]]:
    query = "SELECT * FROM incoming_transactions"
    if not include_claimed:
        query += " WHERE claimed = 0"
    query += " ORDER BY occurred_at DESC"

    with get_connection() as conn:
        rows = conn.execute(query).fetchall()

    return [
        {
            "uuid": row["uuid"],
            "merchant": row["merchant"],
            "amount": row["amount"],
            "currency_code": row["currency_code"],
            "raw_text": row["raw_text"],
            "source_app": row["source_app"],
            "occurred_at": row["occurred_at"],
            "received_at": row["received_at"],
            "claimed": bool(row["claimed"]),
        }
        for row in rows
    ]


def mark_claimed(uuids: list[str]) -> int:
    if not uuids:
        return 0
    placeholders = ",".join("?" for _ in uuids)
    with get_connection() as conn:
        cursor = conn.execute(
            f"UPDATE incoming_transactions SET claimed = 1 WHERE uuid IN ({placeholders})",
            uuids,
        )
        return cursor.rowcount


def count_unclaimed() -> int:
    with get_connection() as conn:
        row = conn.execute(
            "SELECT COUNT(*) AS n FROM incoming_transactions WHERE claimed = 0"
        ).fetchone()
        return int(row["n"])
