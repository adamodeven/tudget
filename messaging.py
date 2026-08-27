"""Picks the outbound/media-download client for the configured messaging
channel (Twilio SMS/MMS or iMessage via BlueBubbles). Everything else in
the app (main.py, plaid_client.py) talks to whichever client this returns
through the same two methods: send(to, body) and download_media(url).
"""

from __future__ import annotations

import logging
from typing import Protocol

from config import AppConfig

logger = logging.getLogger(__name__)


class MessagingClient(Protocol):
    def send(self, to: str, body: str) -> None: ...
    def download_media(self, media_url: str) -> tuple[bytes, str]: ...


class NullMessagingClient:
    """Used when messaging.channel is "none" -- the iOS app is the front end,
    so there's nobody to text. Messages are logged instead of sent, and the
    transactions themselves still land in SQLite/Notion for the app to pull."""

    def send(self, to: str | None, body: str) -> None:
        logger.info("[messaging disabled] would have sent: %s", body)

    def download_media(self, media_url: str) -> tuple[bytes, str]:
        raise NotImplementedError("No messaging channel configured")


def get_messaging_client(config: AppConfig) -> MessagingClient:
    if config.messaging.channel == "none":
        return NullMessagingClient()

    if config.messaging.channel == "imessage":
        import imessage_client

        return imessage_client.IMessageClient(config)

    import twilio_client

    return twilio_client.TwilioClient(config)


def notify_target(config: AppConfig) -> str | None:
    """The address unprompted/automated messages (new-transaction alerts,
    nightly reconciliation summaries) are sent to, or None when no messaging
    channel is configured."""
    if config.messaging.channel == "none":
        return None
    if config.messaging.channel == "imessage":
        return config.imessage.my_handle
    return config.phone.my_number
