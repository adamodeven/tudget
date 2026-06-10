"""Polls Gmail for bank transaction-alert emails and triggers the SMS flow.

On a fixed interval (config.gmail.poll_interval_seconds), lists recent
messages from the configured bank senders, parses any that look like
purchase alerts, and calls back into main.py with the parsed transaction.
Already-seen messages are tracked in the processed_emails table so a
restart doesn't re-trigger old alerts.
"""

from __future__ import annotations

import asyncio
import base64
import logging
import re
from email import message_from_bytes
from email.policy import default as email_policy
from pathlib import Path
from typing import Awaitable, Callable

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build

import db
from bank_parsers import BANK_PARSERS
from config import AppConfig

logger = logging.getLogger(__name__)

SCOPES = ["https://www.googleapis.com/auth/gmail.readonly"]
UNPARSED_LOG = Path(__file__).parent / "data" / "unparsed_emails.log"

OnNewTransaction = Callable[[dict], Awaitable[None]]


def get_gmail_service(config: AppConfig):
    creds = None
    token_path = Path(config.gmail.token_file)
    if token_path.exists():
        creds = Credentials.from_authorized_user_file(str(token_path), SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file(config.gmail.credentials_file, SCOPES)
            creds = flow.run_local_server(port=0)
        token_path.write_text(creds.to_json())

    return build("gmail", "v1", credentials=creds, cache_discovery=False)


def build_query(config: AppConfig) -> str:
    senders = config.bank_senders
    sender_clause = " OR ".join(f"from:{addr}" for addr in senders.values())
    query = f"({sender_clause})" if sender_clause else ""
    if config.gmail.label:
        query = f"{query} label:{config.gmail.label}".strip()
    return query


def _strip_html(html: str) -> str:
    text = re.sub(r"<[^>]+>", " ", html)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def get_message_content(service, msg_id: str) -> tuple[str, str, str]:
    """Returns (sender, subject, body_text) for a Gmail message."""
    raw_msg = service.users().messages().get(userId="me", id=msg_id, format="raw").execute()
    raw_bytes = base64.urlsafe_b64decode(raw_msg["raw"])
    email_msg = message_from_bytes(raw_bytes, policy=email_policy)

    sender = email_msg.get("From", "")
    subject = email_msg.get("Subject", "")

    body = ""
    if email_msg.is_multipart():
        plain_part = email_msg.get_body(preferencelist=("plain",))
        if plain_part is not None:
            body = plain_part.get_content()
        else:
            html_part = email_msg.get_body(preferencelist=("html",))
            if html_part is not None:
                body = _strip_html(html_part.get_content())
    else:
        if email_msg.get_content_type() == "text/plain":
            body = email_msg.get_content()
        else:
            body = _strip_html(email_msg.get_content())

    return sender, subject, body


def match_bank(sender: str, config: AppConfig) -> str | None:
    sender_lower = sender.lower()
    for bank_key, sender_addr in config.bank_senders.items():
        if sender_addr.lower() in sender_lower:
            return bank_key
    return None


def parse_email(sender: str, subject: str, body: str, config: AppConfig) -> dict | None:
    bank_key = match_bank(sender, config)
    if bank_key is None:
        return None
    parser = BANK_PARSERS.get(bank_key)
    if parser is None:
        return None
    return parser(subject, body)


def _log_unparsed(sender: str, subject: str, body: str) -> None:
    UNPARSED_LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(UNPARSED_LOG, "a") as f:
        f.write(f"--- From: {sender}\nSubject: {subject}\n\n{body}\n\n")


async def poll_once(service, config: AppConfig, on_new_transaction: OnNewTransaction) -> None:
    query = build_query(config)
    if not query:
        return

    results = service.users().messages().list(userId="me", q=query, maxResults=20).execute()
    messages = results.get("messages", [])

    # Process oldest-first so SMS alerts arrive in chronological order.
    for msg_meta in reversed(messages):
        msg_id = msg_meta["id"]
        if db.is_email_processed(msg_id):
            continue

        sender, subject, body = get_message_content(service, msg_id)
        parsed = parse_email(sender, subject, body, config)

        if parsed:
            await on_new_transaction(parsed)
        elif match_bank(sender, config) is not None:
            logger.warning("Could not parse transaction alert from %s", sender)
            _log_unparsed(sender, subject, body)

        db.mark_email_processed(msg_id)


async def poll_loop(config: AppConfig, on_new_transaction: OnNewTransaction) -> None:
    service = get_gmail_service(config)
    while True:
        try:
            await poll_once(service, config, on_new_transaction)
        except Exception:
            logger.exception("Gmail poll failed")
        await asyncio.sleep(config.gmail.poll_interval_seconds)


if __name__ == "__main__":
    # One-time interactive OAuth setup. Run this locally (it opens a
    # browser) before starting the server for the first time.
    from config import load_config

    cfg = load_config()
    get_gmail_service(cfg)
    print(f"Gmail credentials saved to {cfg.gmail.token_file}")
