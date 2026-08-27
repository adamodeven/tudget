"""Tudget ingest server.

Parked scaffolding for one future job: an Android phone running a
notification listener intercepts a bank's purchase alert, POSTs it here, and
Tudget on iOS pulls it down so you get reminded to categorize a purchase you
never typed in.

iOS gives no app permission to read another app's notifications, which is why
this lives on an Android device rather than in the app. Until that device
exists, nothing talks to this server -- the iOS app is complete without it.

Deliberately small: no Twilio, no Gmail, no Plaid, no Notion. Two endpoints
behind one bearer token, and a SQLite file.
"""

from __future__ import annotations

import logging
import os
import secrets
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Annotated

import yaml
from fastapi import Depends, FastAPI, Header, HTTPException, Query, status
from pydantic import BaseModel, Field

import db

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("tudget")

CONFIG_PATH = os.environ.get("TUDGET_CONFIG", "config.yaml")


class Config(BaseModel):
    """Server config. The token is the only thing that must be set."""

    token: str
    host: str = "0.0.0.0"
    port: int = 8000


def load_config(path: str = CONFIG_PATH) -> Config:
    if not os.path.exists(path):
        raise FileNotFoundError(
            f"{path} not found. Copy config.example.yaml to {path} and set a token "
            '(generate one with: python -c "import secrets; print(secrets.token_urlsafe(32))")'
        )
    with open(path) as handle:
        raw = yaml.safe_load(handle) or {}
    return Config(**raw)


config = load_config()


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def require_token(authorization: Annotated[str | None, Header()] = None) -> None:
    """Bearer-token auth on every route.

    Compared with `compare_digest` so a wrong token can't be discovered a
    character at a time by timing the response.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    supplied = authorization.removeprefix("Bearer ").strip()
    if not secrets.compare_digest(supplied, config.token):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Bad token"
        )


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class IncomingTransaction(BaseModel):
    """One intercepted purchase notification."""

    # The Android client generates this, so a retry after a flaky response
    # updates the same row instead of creating a duplicate.
    uuid: str
    merchant: str = ""
    amount: float
    currency_code: str = Field(default="USD", max_length=3, min_length=3)
    # Free text: whatever the notification said, kept so a bad parse upstream
    # is still recoverable by hand.
    raw_text: str | None = None
    source_app: str | None = None
    occurred_at: datetime | None = None


class StoredTransaction(IncomingTransaction):
    received_at: datetime
    claimed: bool


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()
    logger.info("Tudget ingest server ready")
    yield


app = FastAPI(
    title="Tudget ingest",
    version="1.0",
    lifespan=lifespan,
    dependencies=[Depends(require_token)],
)


@app.get("/api/health")
async def health() -> dict:
    return {"status": "ok", "pending": db.count_unclaimed()}


@app.post("/api/transactions", status_code=status.HTTP_201_CREATED)
async def ingest(transaction: IncomingTransaction) -> dict:
    """Called by the Android notification listener."""
    occurred = transaction.occurred_at or datetime.now(timezone.utc)
    created = db.upsert_transaction(
        uuid=transaction.uuid,
        merchant=transaction.merchant,
        amount=transaction.amount,
        currency_code=transaction.currency_code.upper(),
        raw_text=transaction.raw_text,
        source_app=transaction.source_app,
        occurred_at=occurred.isoformat(),
    )
    logger.info(
        "%s %s %.2f %s",
        "Stored" if created else "Updated",
        transaction.merchant or "(unknown)",
        transaction.amount,
        transaction.currency_code,
    )
    return {"stored": True, "created": created, "uuid": transaction.uuid}


@app.get("/api/transactions")
async def pending(
    include_claimed: bool = Query(
        False, description="Include transactions the app has already taken."
    )
) -> list[StoredTransaction]:
    """Called by the iOS app to pull anything it hasn't seen."""
    return [StoredTransaction(**row) for row in db.list_transactions(include_claimed)]


@app.post("/api/transactions/claim")
async def claim(uuids: list[str]) -> dict:
    """Marks transactions as taken, so the app doesn't import them twice."""
    claimed = db.mark_claimed(uuids)
    return {"claimed": claimed}
