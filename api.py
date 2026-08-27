"""JSON API the iOS app syncs into.

The app is the source of truth and works entirely on-device; this endpoint
exists so the pieces a phone can't do -- the Notion dashboard, bank-alert
email parsing, Plaid reconciliation -- still see everything logged on the
phone. It's off unless `api.enabled` is true in config.yaml.

Auth is a single shared bearer token (`api.token`), which is proportionate
for a one-user self-hosted server. Put it behind HTTPS (ngrok already is)
so the token isn't sent in the clear.
"""

from __future__ import annotations

import logging
import secrets
from datetime import datetime

from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException, status
from pydantic import BaseModel, Field

import db
import notion_sync
from config import AppConfig

logger = logging.getLogger(__name__)


class TransactionIn(BaseModel):
    """One purchase as the iOS app sends it. `amount`/`currency` are the
    purchase as it happened; `amount_default_currency` is the app's own
    conversion, trusted as-is so the phone and server agree on budget totals
    even if they'd fetch slightly different FX rates."""

    id: str
    merchant: str
    amount: float
    currency: str = "USD"
    amount_default_currency: float | None = None
    card: str = "Manual"
    category: str | None = None
    timestamp: str | None = None
    source: str = "manual"
    note: str | None = None


class TransactionBatch(BaseModel):
    transactions: list[TransactionIn] = Field(default_factory=list)


class SyncResult(BaseModel):
    created: int
    updated: int


def build_router(config: AppConfig) -> APIRouter:
    router = APIRouter(prefix="/api", tags=["app"])

    def require_token(authorization: str | None = Header(default=None)) -> None:
        """Bearer-token check, compared in constant time so the endpoint
        doesn't leak the token a character at a time."""
        expected = config.api.token or ""
        provided = ""
        if authorization and authorization.lower().startswith("bearer "):
            provided = authorization[7:].strip()

        if not expected or not secrets.compare_digest(provided, expected):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid or missing API token",
                headers={"WWW-Authenticate": "Bearer"},
            )

    @router.get("/health")
    async def api_health(_: None = Depends(require_token)) -> dict:
        """Lets the app verify its URL and token before trying a real sync."""
        return {"status": "ok", "default_currency": config.currency.default_currency}

    @router.get("/categories")
    async def list_categories(_: None = Depends(require_token)) -> dict:
        """The budget as Notion has it, so the app can adopt limits set there."""
        return {
            "default_currency": config.currency.default_currency,
            "categories": [
                {
                    "name": row["name"],
                    "monthly_limit": row["monthly_limit"],
                    "emoji": row["emoji"],
                }
                for row in db.get_categories()
            ],
        }

    @router.post("/transactions", response_model=SyncResult)
    async def upsert_transactions(
        batch: TransactionBatch,
        background_tasks: BackgroundTasks,
        _: None = Depends(require_token),
    ) -> SyncResult:
        created = 0
        updated = 0

        for incoming in batch.transactions:
            timestamp = incoming.timestamp or datetime.now().isoformat()
            amount_default = (
                incoming.amount_default_currency
                if incoming.amount_default_currency is not None
                else incoming.amount
            )

            existing = db.get_transaction_by_client_id(incoming.id)
            if existing:
                db.update_transaction(
                    existing["id"],
                    merchant=incoming.merchant,
                    amount=incoming.amount,
                    currency=incoming.currency,
                    amount_default_currency=amount_default,
                    card=incoming.card,
                    category=incoming.category,
                    timestamp=timestamp,
                )
                transaction_id = existing["id"]
                updated += 1
            else:
                transaction_id = db.insert_transaction(
                    merchant=incoming.merchant,
                    amount=incoming.amount,
                    currency=incoming.currency,
                    amount_default_currency=amount_default,
                    card=incoming.card,
                    category=incoming.category,
                    timestamp=timestamp,
                    source=incoming.source,
                    client_id=incoming.id,
                )
                created += 1

            # Notion writes are slow and must never make the phone's sync
            # request hang or fail -- the ledger row is already saved.
            background_tasks.add_task(_sync_to_notion, transaction_id, config)

        logger.info("App sync: %d created, %d updated", created, updated)
        return SyncResult(created=created, updated=updated)

    return router


def _sync_to_notion(transaction_id: int, config: AppConfig) -> None:
    try:
        notion_sync.sync_transaction(transaction_id, config)
    except Exception:
        logger.exception("Notion sync failed for transaction %s", transaction_id)
