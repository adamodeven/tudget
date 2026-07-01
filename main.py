"""FastAPI app: Twilio webhook, the Android relay device's notification
webhook, manual reconciliation trigger, and the background jobs that tie
everything together (hourly category refresh from Notion, nightly Plaid
reconciliation)."""

from __future__ import annotations

import asyncio
import hashlib
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from pathlib import Path

from fastapi import BackgroundTasks, FastAPI, Form, Header, HTTPException, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from twilio.twiml.messaging_response import MessagingResponse

import db
import notification_parsers
import notion_sync
import plaid_client
import twilio_client as twilio_client_module
from config import load_config

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

UNPARSED_LOG = Path(__file__).parent / "data" / "unparsed_notifications.log"

config = load_config()
twilio_client = twilio_client_module.TwilioClient(config)
notion = notion_sync.get_notion_client(config)


class NotificationPayload(BaseModel):
    """Body posted by the relay device's notification-forwarder app for
    each bank app notification (see README's "Android relay device"
    section)."""

    package: str
    title: str = ""
    text: str = ""


async def on_new_transaction(parsed: dict) -> None:
    """Called for each newly parsed bank app notification."""
    transaction_id = db.insert_transaction(
        merchant=parsed["merchant"],
        amount=parsed["amount"],
        card=parsed["card"],
        timestamp=datetime.now().isoformat(),
        source="notification",
    )
    db.create_pending_categorization(transaction_id, config.phone.my_number)

    categories = db.get_categories()
    message = twilio_client_module.format_new_transaction_message(
        parsed["card"], parsed["merchant"], parsed["amount"], categories
    )
    twilio_client.send_sms(config.phone.my_number, message)


def _log_unparsed_notification(package: str, title: str, text: str) -> None:
    UNPARSED_LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(UNPARSED_LOG, "a") as f:
        f.write(f"--- Package: {package}\nTitle: {title}\n\n{text}\n\n")


async def category_refresh_loop() -> None:
    while True:
        await asyncio.sleep(config.notion.category_refresh_interval_seconds)
        try:
            categories = notion_sync.fetch_categories(notion, config.notion.categories_db_id)
            db.replace_categories(categories)
            logger.info("Refreshed %d categories from Notion", len(categories))
        except Exception:
            logger.exception("Category refresh failed")


async def reconciliation_scheduler() -> None:
    while True:
        now = datetime.now()
        target = now.replace(hour=config.plaid.reconciliation_hour, minute=0, second=0, microsecond=0)
        if target <= now:
            target += timedelta(days=1)
        await asyncio.sleep((target - now).total_seconds())
        try:
            plaid_client.run_reconciliation(config, twilio_client)
        except Exception:
            logger.exception("Nightly reconciliation failed")


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()

    categories = notion_sync.fetch_categories(notion, config.notion.categories_db_id)
    db.replace_categories(categories)
    logger.info("Loaded %d categories from Notion", len(categories))

    tasks = [asyncio.create_task(category_refresh_loop())]
    if config.plaid.enabled:
        tasks.append(asyncio.create_task(reconciliation_scheduler()))
    try:
        yield
    finally:
        for task in tasks:
            task.cancel()


app = FastAPI(lifespan=lifespan)

Path(config.receipts.storage_dir).mkdir(parents=True, exist_ok=True)
app.mount("/receipts", StaticFiles(directory=config.receipts.storage_dir), name="receipts")


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/sms")
async def sms_webhook(
    background_tasks: BackgroundTasks,
    From: str = Form(...),
    Body: str = Form(""),
    NumMedia: str = Form("0"),
    MediaUrl0: str | None = Form(None),
) -> Response:
    twiml = MessagingResponse()

    if From != config.phone.my_number:
        logger.warning("Ignoring SMS from unrecognized number: %s", From)
        return Response(content=str(twiml), media_type="application/xml")

    media_url = MediaUrl0 if int(NumMedia or "0") > 0 else None
    categories = db.get_categories()

    reply_text, sync_info = twilio_client_module.handle_incoming_message(
        From, Body, media_url, categories, twilio_client, config.receipts.storage_dir
    )

    if sync_info:
        background_tasks.add_task(notion_sync.sync_transaction, sync_info["transaction_id"], config)

    twiml.message(reply_text)
    return Response(content=str(twiml), media_type="application/xml")


@app.post("/notification")
async def notification_webhook(
    payload: NotificationPayload,
    x_tudget_secret: str = Header(default=""),
) -> dict:
    """Receives bank app push notifications forwarded from the Android
    relay device (see README's "Android relay device" section)."""
    if x_tudget_secret != config.notification.shared_secret:
        raise HTTPException(status_code=401, detail="invalid secret")

    bank_key = config.notification.apps.get(payload.package)
    if bank_key is None:
        return {"status": "ignored"}

    notification_hash = hashlib.sha256(
        f"{payload.package}|{payload.title}|{payload.text}".encode()
    ).hexdigest()
    if db.is_notification_processed(notification_hash):
        return {"status": "duplicate"}
    db.mark_notification_processed(notification_hash)

    parser = notification_parsers.BANK_PARSERS.get(bank_key)
    parsed = parser(payload.title, payload.text) if parser else None

    if parsed is None:
        logger.warning("Could not parse notification from %s", payload.package)
        _log_unparsed_notification(payload.package, payload.title, payload.text)
        return {"status": "unparsed"}

    await on_new_transaction(parsed)
    return {"status": "ok"}


@app.post("/reconcile")
async def trigger_reconciliation() -> dict:
    """Manually runs the nightly reconciliation job (see README)."""
    if not config.plaid.enabled:
        raise HTTPException(status_code=503, detail="Plaid is disabled (set plaid.enabled: true in config.yaml)")
    return plaid_client.run_reconciliation(config, twilio_client)
