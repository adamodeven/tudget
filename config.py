"""Loads and validates config.yaml.

Never hardcode secrets: everything sensitive lives in config.yaml, which is
gitignored. config.example.yaml documents every required key.
"""

from __future__ import annotations

from pathlib import Path

import yaml
from pydantic import BaseModel, Field

CONFIG_PATH = Path(__file__).parent / "config.yaml"


class ServerConfig(BaseModel):
    host: str = "0.0.0.0"
    port: int = 8000
    base_url: str


class PhoneConfig(BaseModel):
    my_number: str


class GmailConfig(BaseModel):
    credentials_file: str = "credentials.json"
    token_file: str = "token.json"
    poll_interval_seconds: int = 60
    label: str = "INBOX"


class TwilioConfig(BaseModel):
    account_sid: str
    auth_token: str
    from_number: str


class NotionConfig(BaseModel):
    api_key: str
    categories_db_id: str
    transactions_db_id: str
    budget_summary_db_id: str
    category_refresh_interval_seconds: int = 3600


class PlaidAccountConfig(BaseModel):
    name: str
    access_token: str
    account_id: str


class PlaidConfig(BaseModel):
    client_id: str
    secret: str
    environment: str = "sandbox"
    reconciliation_hour: int = 2
    accounts: list[PlaidAccountConfig] = Field(default_factory=list)


class ReceiptsConfig(BaseModel):
    storage_dir: str = "data/receipts"


class AppConfig(BaseModel):
    server: ServerConfig
    phone: PhoneConfig
    gmail: GmailConfig
    twilio: TwilioConfig
    notion: NotionConfig
    plaid: PlaidConfig
    receipts: ReceiptsConfig = Field(default_factory=ReceiptsConfig)
    bank_senders: dict[str, str] = Field(default_factory=dict)


def load_config(path: Path | str = CONFIG_PATH) -> AppConfig:
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(
            f"{path} not found. Copy config.example.yaml to {path.name} "
            "and fill in your values."
        )
    with open(path) as f:
        raw = yaml.safe_load(f)
    return AppConfig(**raw)
