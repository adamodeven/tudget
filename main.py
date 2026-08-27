"""FastAPI app: inbound-message webhooks (Twilio SMS or iMessage/BlueBubbles,
per config), manual reconciliation trigger, and the background jobs that
tie everything together (optional Gmail polling, hourly category refresh
from Notion, optional nightly Plaid reconciliation)."""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from pathlib import Path

from fastapi import BackgroundTasks, Body, FastAPI, Form, Response
from fastapi.staticfiles import StaticFiles
from twilio.twiml.messaging_response import MessagingResponse

import api
import currency
import db
import gmail_poller
import imessage_client
import inbound
import messaging
import notion_sync
import plaid_client
from config import load_config

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

config = load_config()
messaging_client = messaging.get_messaging_client(config)
notion = notion_sync.get_notion_client(config)


async def on_new_transaction(parsed: dict) -> None:
    """Called by the Gmail poller for each newly parsed bank alert."""
    currency_code = parsed.get("currency") or config.currency.default_currency
    amount_default = currency.convert(parsed["amount"], currency_code, config.currency.default_currency)

    transaction_id = db.insert_transaction(
        merchant=parsed["merchant"],
        amount=parsed["amount"],
        currency=currency_code,
        amount_default_currency=amount_default,
        card=parsed["card"],
        timestamp=datetime.now().isoformat(),
        source="email",
    )

    target = messaging.notify_target(config)
    if target is None:
        # No messaging channel: the iOS app picks this up over the API and
        # categorizes it there, so there's no pending reply to track.
        logger.info(
            "Logged %s %s from email; no messaging channel, app will pick it up",
            parsed["merchant"], parsed["amount"],
        )
        return

    db.create_pending_categorization(transaction_id, target)

    categories = db.get_categories()
    message = inbound.format_new_transaction_message(
        parsed["card"], parsed["merchant"], parsed["amount"], currency_code, categories
    )
    messaging_client.send(target, message)


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
            plaid_client.run_reconciliation(config, messaging_client)
        except Exception:
            logger.exception("Nightly reconciliation failed")


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()

    categories = notion_sync.fetch_categories(notion, config.notion.categories_db_id)
    db.replace_categories(categories)
    logger.info("Loaded %d categories from Notion", len(categories))

    tasks = [asyncio.create_task(category_refresh_loop())]
    if config.gmail.enabled:
        tasks.append(asyncio.create_task(gmail_poller.poll_loop(config, on_new_transaction)))
    else:
        logger.info("Gmail polling is disabled (gmail.enabled: false) -- manual/screenshot entry only")
    if config.plaid.enabled:
        tasks.append(asyncio.create_task(reconciliation_scheduler()))
    else:
        logger.info("Plaid reconciliation is disabled (plaid.enabled: false)")

    try:
        yield
    finally:
        for task in tasks:
            task.cancel()


app = FastAPI(lifespan=lifespan)

Path(config.receipts.storage_dir).mkdir(parents=True, exist_ok=True)
app.mount("/receipts", StaticFiles(directory=config.receipts.storage_dir), name="receipts")

if config.api.enabled:
    app.include_router(api.build_router(config))
    logger.info("App sync API enabled at /api")


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

    if config.messaging.channel != "twilio":
        return Response(content=str(twiml), media_type="application/xml")

    if From != config.phone.my_number:
        logger.warning("Ignoring SMS from unrecognized number: %s", From)
        return Response(content=str(twiml), media_type="application/xml")

    media_bytes = media_content_type = None
    if int(NumMedia or "0") > 0 and MediaUrl0:
        media_bytes, media_content_type = messaging_client.download_media(MediaUrl0)

    categories = db.get_categories()
    reply_text, sync_info = inbound.handle_incoming_message(
        From, Body, media_bytes, media_content_type, categories,
        config.receipts.storage_dir, config.currency.default_currency,
    )

    if sync_info:
        background_tasks.add_task(notion_sync.sync_transaction, sync_info["transaction_id"], config)

    twiml.message(reply_text)
    return Response(content=str(twiml), media_type="application/xml")


@app.post("/imessage/webhook")
async def imessage_webhook(background_tasks: BackgroundTasks, payload: dict = Body(...)) -> dict:
    if config.messaging.channel != "imessage":
        return {"ok": False}

    event = imessage_client.parse_webhook_event(payload)
    if event is None:
        return {"ok": True}

    if event["from"] != config.imessage.my_handle:
        logger.warning("Ignoring iMessage from unrecognized handle: %s", event["from"])
        return {"ok": True}

    media_bytes = media_content_type = None
    if event["media_url"]:
        media_bytes, media_content_type = messaging_client.download_media(event["media_url"])

    categories = db.get_categories()
    reply_text, sync_info = inbound.handle_incoming_message(
        event["from"], event["body"], media_bytes, media_content_type, categories,
        config.receipts.storage_dir, config.currency.default_currency,
    )

    if sync_info:
        background_tasks.add_task(notion_sync.sync_transaction, sync_info["transaction_id"], config)

    messaging_client.send(event["from"], reply_text)
    return {"ok": True}


@app.post("/reconcile")
async def trigger_reconciliation() -> dict:
    """Manually runs the nightly reconciliation job (see README)."""
    return plaid_client.run_reconciliation(config, messaging_client)
