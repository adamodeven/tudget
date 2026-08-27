import pytest
from pydantic import ValidationError

from config import AppConfig

NOTION = {
    "api_key": "k",
    "categories_db_id": "a",
    "transactions_db_id": "b",
    "budget_summary_db_id": "c",
}


def build(**overrides):
    base = {"server": {"base_url": "https://example.test"}, "notion": NOTION}
    base.update(overrides)
    return AppConfig(**base)


# ---------------------------------------------------------------------------
# Messaging channels
# ---------------------------------------------------------------------------

def test_twilio_channel_requires_credentials():
    with pytest.raises(ValidationError, match="account_sid"):
        build(messaging={"channel": "twilio"})


def test_twilio_channel_accepts_full_credentials():
    config = build(
        messaging={"channel": "twilio"},
        phone={"my_number": "+15555550123"},
        twilio={"account_sid": "AC1", "auth_token": "t", "from_number": "+15555550100"},
    )
    assert config.messaging.channel == "twilio"


def test_imessage_channel_requires_bluebubbles_settings():
    with pytest.raises(ValidationError, match="imessage"):
        build(messaging={"channel": "imessage"})


def test_unknown_channel_is_rejected():
    with pytest.raises(ValidationError, match="carrier-pigeon"):
        build(messaging={"channel": "carrier-pigeon"})


# ---------------------------------------------------------------------------
# App-only mode
# ---------------------------------------------------------------------------

def test_channel_none_without_api_leaves_no_way_to_reach_the_user():
    with pytest.raises(ValidationError, match="nothing can reach you"):
        build(messaging={"channel": "none"})


def test_channel_none_with_api_is_the_ios_app_setup():
    config = build(
        messaging={"channel": "none"},
        api={"enabled": True, "token": "secret"},
    )
    assert config.messaging.channel == "none"
    assert config.api.enabled


def test_api_without_token_is_rejected():
    with pytest.raises(ValidationError, match="api.token"):
        build(messaging={"channel": "none"}, api={"enabled": True})


# ---------------------------------------------------------------------------
# Optional automation stays optional
# ---------------------------------------------------------------------------

def test_gmail_and_plaid_default_to_off():
    config = build(messaging={"channel": "none"}, api={"enabled": True, "token": "s"})
    assert not config.gmail.enabled
    assert not config.plaid.enabled


def test_gmail_enabled_requires_bank_senders():
    with pytest.raises(ValidationError, match="bank_senders"):
        build(
            messaging={"channel": "none"},
            api={"enabled": True, "token": "s"},
            gmail={"enabled": True},
        )


def test_default_currency_defaults_to_usd():
    config = build(messaging={"channel": "none"}, api={"enabled": True, "token": "s"})
    assert config.currency.default_currency == "USD"
