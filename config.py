"""Loads and validates config.yaml.

Never hardcode secrets: everything sensitive lives in config.yaml, which is
gitignored. config.example.yaml documents every required key.
"""

from __future__ import annotations

from pathlib import Path

import yaml
from pydantic import BaseModel, Field, model_validator

CONFIG_PATH = Path(__file__).parent / "config.yaml"


class ServerConfig(BaseModel):
    host: str = "0.0.0.0"
    port: int = 8000
    base_url: str


class PhoneConfig(BaseModel):
    # Required only when messaging.channel is "twilio" -- the number
    # allowed to text the bot, and the target for automated alerts.
    my_number: str | None = None


class MessagingConfig(BaseModel):
    # "twilio" (SMS/MMS), "imessage" (see imessage_client.py), or "none" --
    # "none" is what you want when the iOS app is your front end and the
    # server is just the Notion/Gmail/Plaid backend behind it.
    channel: str = "twilio"


class GmailConfig(BaseModel):
    # Off by default: Tudget is fully usable via manual text/screenshot
    # entry alone. Turn this on once you've set up bank email alerts (see
    # README) for automatic transaction detection.
    enabled: bool = False
    credentials_file: str = "credentials.json"
    token_file: str = "token.json"
    poll_interval_seconds: int = 60
    label: str = "INBOX"


class TwilioConfig(BaseModel):
    account_sid: str | None = None
    auth_token: str | None = None
    from_number: str | None = None


class IMessageConfig(BaseModel):
    server_url: str | None = None
    password: str | None = None
    my_handle: str | None = None


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
    # Off by default, same reasoning as gmail.enabled -- this is the
    # nightly bank-reconciliation safety net, not required to use Tudget.
    enabled: bool = False
    client_id: str | None = None
    secret: str | None = None
    environment: str = "sandbox"
    reconciliation_hour: int = 2
    accounts: list[PlaidAccountConfig] = Field(default_factory=list)


class ReceiptsConfig(BaseModel):
    storage_dir: str = "data/receipts"


class ApiConfig(BaseModel):
    """JSON API the iOS app syncs into. Off unless you're using the app."""

    enabled: bool = False
    # Shared secret the app sends as `Authorization: Bearer <token>`.
    # Generate one with: python -c "import secrets; print(secrets.token_urlsafe(32))"
    token: str | None = None


class CurrencyConfig(BaseModel):
    # All budgets/limits and cross-category totals are tracked in this
    # currency; purchases made in other currencies are converted to it
    # (see currency.py) using live FX rates.
    default_currency: str = "USD"


class AppConfig(BaseModel):
    server: ServerConfig
    phone: PhoneConfig = Field(default_factory=PhoneConfig)
    messaging: MessagingConfig = Field(default_factory=MessagingConfig)
    gmail: GmailConfig = Field(default_factory=GmailConfig)
    twilio: TwilioConfig = Field(default_factory=TwilioConfig)
    imessage: IMessageConfig = Field(default_factory=IMessageConfig)
    notion: NotionConfig
    plaid: PlaidConfig = Field(default_factory=PlaidConfig)
    receipts: ReceiptsConfig = Field(default_factory=ReceiptsConfig)
    currency: CurrencyConfig = Field(default_factory=CurrencyConfig)
    api: ApiConfig = Field(default_factory=ApiConfig)
    bank_senders: dict[str, str] = Field(default_factory=dict)

    @model_validator(mode="after")
    def _check_conditional_requirements(self) -> "AppConfig":
        if self.messaging.channel == "twilio":
            missing = [f for f in ("account_sid", "auth_token", "from_number") if not getattr(self.twilio, f)]
            if not self.phone.my_number:
                missing.append("phone.my_number")
            if missing:
                raise ValueError(
                    f"messaging.channel is 'twilio' but these are not set: {', '.join(missing)}"
                )
        elif self.messaging.channel == "imessage":
            missing = [f for f in ("server_url", "password", "my_handle") if not getattr(self.imessage, f)]
            if missing:
                raise ValueError(
                    f"messaging.channel is 'imessage' but imessage.{missing[0]} is not set"
                )
        elif self.messaging.channel == "none":
            # No outbound texting: the iOS app is the front end. Nothing to
            # validate, but there'd be no way to reach the user without the
            # API, so make that an explicit requirement rather than a silent
            # dead end.
            if not self.api.enabled:
                raise ValueError(
                    "messaging.channel is 'none', so nothing can reach you -- "
                    "enable the API (api.enabled: true) for the iOS app, or pick "
                    "a messaging channel"
                )
        else:
            raise ValueError(
                f"messaging.channel must be 'twilio', 'imessage', or 'none', "
                f"got {self.messaging.channel!r}"
            )

        if self.api.enabled and not self.api.token:
            raise ValueError(
                "api.enabled is true but api.token is not set -- generate one with: "
                'python -c "import secrets; print(secrets.token_urlsafe(32))"'
            )

        if self.gmail.enabled and not self.bank_senders:
            raise ValueError("gmail.enabled is true but bank_senders is empty")

        if self.plaid.enabled and (not self.plaid.client_id or not self.plaid.secret):
            raise ValueError("plaid.enabled is true but plaid.client_id/secret are not set")

        return self


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
