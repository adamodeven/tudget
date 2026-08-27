"""Twilio SMS/MMS transport: sending replies/alerts and downloading inbound
media. Message parsing/routing logic lives in inbound.py -- it's shared
with the iMessage channel (see messaging.py, imessage_client.py)."""

from __future__ import annotations

import requests
from twilio.rest import Client

from config import AppConfig


class TwilioClient:
    def __init__(self, config: AppConfig):
        self.client = Client(config.twilio.account_sid, config.twilio.auth_token)
        self.account_sid = config.twilio.account_sid
        self.auth_token = config.twilio.auth_token
        self.from_number = config.twilio.from_number

    def send(self, to: str, body: str) -> None:
        self.client.messages.create(to=to, from_=self.from_number, body=body)

    def download_media(self, media_url: str) -> tuple[bytes, str]:
        resp = requests.get(media_url, auth=(self.account_sid, self.auth_token), timeout=30)
        resp.raise_for_status()
        content_type = resp.headers.get("Content-Type", "image/jpeg")
        return resp.content, content_type
