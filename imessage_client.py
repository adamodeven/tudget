"""iMessage channel via BlueBubbles.

A personal Apple Developer Program membership ($99/year) does not, on its
own, grant access to any API for sending/receiving iMessage. Apple's only
official programmatic channel is Messages for Business (Business Chat),
which requires enrolling as a business through Apple Business Register and
getting approved -- it's built for companies messaging customers at scale,
not a single-user personal bot, and approval isn't available to individual
developer accounts.

The practical, widely-used way to run a personal iMessage bot is
BlueBubbles (https://bluebubbles.app, open source, free): a small server
you run on a Mac that's signed into Messages.app with an Apple ID -- a
spare Mac mini or old MacBook works, as does a rented cloud Mac (e.g. an
AWS EC2 Mac instance or MacStadium). BlueBubbles exposes a REST API to
send messages and a webhook to receive them, which is what this module
talks to. It's best to point that Mac's Messages.app at a dedicated "bot"
Apple ID rather than your personal one, and text it from your own number.

Setup:
1. Install BlueBubbles Server on a Mac that's always on and signed into
   Messages.app: https://bluebubbles.app/install/
2. In BlueBubbles Server settings, set a server password and note its
   local/Tailscale/ngrok URL.
3. Under Settings -> API & Webhooks, add a webhook pointing at
   `<tudget base_url>/imessage/webhook` for the "New Message" event.
4. Set `messaging.channel: imessage` and fill in the `imessage` section of
   config.yaml (server_url, password, my_handle -- the phone number or
   email allowed to text the bot, i.e. yours).
"""

from __future__ import annotations

import requests

from config import AppConfig


class IMessageClient:
    def __init__(self, config: AppConfig):
        self.base_url = config.imessage.server_url.rstrip("/")
        self.password = config.imessage.password

    def send(self, to: str, body: str) -> None:
        resp = requests.post(
            f"{self.base_url}/api/v1/message/text",
            params={"password": self.password},
            json={"chatGuid": None, "address": to, "message": body, "method": "apple-script"},
            timeout=15,
        )
        resp.raise_for_status()

    def download_media(self, media_url: str) -> tuple[bytes, str]:
        url = media_url if media_url.startswith("http") else f"{self.base_url}{media_url}"
        resp = requests.get(url, params={"password": self.password}, timeout=30)
        resp.raise_for_status()
        content_type = resp.headers.get("Content-Type", "image/jpeg")
        return resp.content, content_type


def parse_webhook_event(payload: dict) -> dict | None:
    """Parses a BlueBubbles 'new-message' webhook payload into
    {"from": str, "body": str, "media_url": str | None}, or None if this
    event isn't an inbound text worth processing (e.g. it's an echo of a
    message the bot itself sent, or carries no sender)."""
    if payload.get("type") != "new-message":
        return None

    data = payload.get("data") or {}
    if data.get("isFromMe"):
        return None

    handle = (data.get("handle") or {}).get("address")
    if not handle:
        return None

    body = data.get("text") or ""

    media_url = None
    attachments = data.get("attachments") or []
    if attachments:
        guid = attachments[0].get("guid")
        if guid:
            media_url = f"/api/v1/attachment/{guid}/download"

    return {"from": handle, "body": body, "media_url": media_url}
