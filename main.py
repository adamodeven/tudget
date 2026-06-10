"""FastAPI app: Twilio webhook, manual reconciliation trigger, and the
background jobs that tie everything together (Gmail polling, hourly
category refresh from Notion, nightly Plaid reconciliation)."""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timedelta
from pathlib import Path

from fastapi import BackgroundTasks, FastAPI, Form, Response
from fastapi.staticfiles import StaticFiles
from twilio.twiml.messaging_response import MessagingResponse

import db
import gmail_poller
import notion_sync
import plaid_client
import twilio_client as twilio_client_module
from config import load_config

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

config = load_config()
twilio_client = twilio_client_module.TwilioClient(config)
notion = notion_sync.get_notion_client(config)


async def on_new_transaction(parsed: dict) -> None:
    """Called by the Gmail poller for each newly parsed bank alert."""
    transaction_id = db.insert_transaction(
        merchant=parsed["merchant"],
        amount=parsed["amount"],
        card=parsed["card"],
        timestamp=datetime.now().isoformat(),
        source="email",
    )
    db.create_pending_categorization(transaction_id, config.phone.my_number)

    categories = db.get_categories()
    message = twilio_client_module.format_new_transaction_message(
        parsed["card"], parsed["merchant"], parsed["amount"], categories
    )
    twilio_client.send_sms(config.phone.my_number, message)


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

    tasks = [
        asyncio.create_task(gmail_poller.poll_loop(config, on_new_transaction)),
        asyncio.create_task(category_refresh_loop()),
        asyncio.create_task(reconciliation_scheduler()),
    ]
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


@app.post("/reconcile")
async def trigger_reconciliation() -> dict:
    """Manually runs the nightly reconciliation job (see README)."""
    return plaid_client.run_reconciliation(config, twilio_client)
