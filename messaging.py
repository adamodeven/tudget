"""Picks the outbound/media-download client for the configured messaging
channel (Twilio SMS/MMS or iMessage via BlueBubbles). Everything else in
the app (main.py, plaid_client.py) talks to whichever client this returns
through the same two methods: send(to, body) and download_media(url).
"""

from __future__ import annotations

from typing import Protocol

from config import AppConfig


class MessagingClient(Protocol):
    def send(self, to: str, body: str) -> None: ...
    def download_media(self, media_url: str) -> tuple[bytes, str]: ...


def get_messaging_client(config: AppConfig) -> MessagingClient:
    if config.messaging.channel == "imessage":
        import imessage_client

        return imessage_client.IMessageClient(config)

    import twilio_client

    return twilio_client.TwilioClient(config)


def notify_target(config: AppConfig) -> str:
    """The address unprompted/automated messages (new-transaction alerts,
    nightly reconciliation summaries) are sent to."""
    if config.messaging.channel == "imessage":
        return config.imessage.my_handle
    return config.phone.my_number
