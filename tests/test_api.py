import pathlib

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

import api
import config as config_module
import db

TOKEN = "test-token-abc123"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


@pytest.fixture
def app_config():
    return config_module.AppConfig(
        server={"base_url": "https://example.test"},
        messaging={"channel": "none"},
        api={"enabled": True, "token": TOKEN},
        currency={"default_currency": "USD"},
        notion={
            "api_key": "k",
            "categories_db_id": "a",
            "transactions_db_id": "b",
            "budget_summary_db_id": "c",
        },
    )


@pytest.fixture
def client(tmp_path, monkeypatch, app_config):
    monkeypatch.setattr(db, "DB_PATH", pathlib.Path(tmp_path) / "test.db")
    db.init_db()
    db.replace_categories([{"name": "Food", "monthly_limit": 400, "emoji": "🍔"}])

    # The API contract is what's under test here, not the Notion round-trip.
    monkeypatch.setattr(api, "_sync_to_notion", lambda transaction_id, cfg: None)

    app = FastAPI()
    app.include_router(api.build_router(app_config))
    return TestClient(app)


def _transaction(client_id, **overrides):
    payload = {
        "id": client_id,
        "merchant": "Cafe Luna",
        "amount": 12.47,
        "currency": "EUR",
        "amount_default_currency": 13.47,
        "category": "Food",
        "timestamp": "2026-08-27T10:00:00",
        "source": "manual",
    }
    payload.update(overrides)
    return payload


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def test_missing_token_is_rejected(client):
    assert client.get("/api/health").status_code == 401


def test_wrong_token_is_rejected(client):
    response = client.get("/api/health", headers={"Authorization": "Bearer nope"})
    assert response.status_code == 401


def test_non_bearer_scheme_is_rejected(client):
    response = client.get("/api/health", headers={"Authorization": TOKEN})
    assert response.status_code == 401


def test_valid_token_is_accepted(client):
    response = client.get("/api/health", headers=AUTH)
    assert response.status_code == 200
    assert response.json()["default_currency"] == "USD"


def test_posting_transactions_requires_auth(client):
    response = client.post(
        "/api/transactions", json={"transactions": [_transaction("abc")]}
    )
    assert response.status_code == 401


# ---------------------------------------------------------------------------
# Categories
# ---------------------------------------------------------------------------

def test_categories_are_returned_for_the_app(client):
    body = client.get("/api/categories", headers=AUTH).json()
    assert body["default_currency"] == "USD"
    assert body["categories"] == [
        {"name": "Food", "monthly_limit": 400.0, "emoji": "🍔"}
    ]


# ---------------------------------------------------------------------------
# Transaction sync
# ---------------------------------------------------------------------------

def test_transactions_are_created(client):
    response = client.post(
        "/api/transactions",
        json={"transactions": [_transaction("id-1"), _transaction("id-2", merchant="TARGET")]},
        headers=AUTH,
    )
    assert response.status_code == 200
    assert response.json() == {"created": 2, "updated": 0}


def test_resyncing_the_same_id_updates_rather_than_duplicates(client):
    payload = {"transactions": [_transaction("id-1")]}
    client.post("/api/transactions", json=payload, headers=AUTH)

    payload["transactions"][0]["merchant"] = "Cafe Luna (renamed)"
    response = client.post("/api/transactions", json=payload, headers=AUTH)

    assert response.json() == {"created": 0, "updated": 1}
    stored = db.get_transaction_by_client_id("id-1")
    assert stored["merchant"] == "Cafe Luna (renamed)"


def test_original_currency_and_converted_amount_are_both_stored(client):
    client.post("/api/transactions", json={"transactions": [_transaction("id-1")]}, headers=AUTH)

    stored = db.get_transaction_by_client_id("id-1")
    assert stored["currency"] == "EUR"
    assert stored["amount"] == pytest.approx(12.47)
    assert stored["amount_default_currency"] == pytest.approx(13.47)


def test_budget_totals_use_the_converted_amount(client):
    client.post(
        "/api/transactions",
        json={
            "transactions": [
                _transaction("id-1"),
                _transaction("id-2", currency="USD", amount=10.0, amount_default_currency=10.0),
            ]
        },
        headers=AUTH,
    )
    # 13.47 (converted from EUR) + 10.00, not 12.47 + 10.00.
    assert db.get_category_spent("Food", 2026, 8) == pytest.approx(23.47)


def test_missing_converted_amount_falls_back_to_the_raw_amount(client):
    payload = _transaction("id-1")
    del payload["amount_default_currency"]
    client.post("/api/transactions", json={"transactions": [payload]}, headers=AUTH)

    stored = db.get_transaction_by_client_id("id-1")
    assert stored["amount_default_currency"] == pytest.approx(12.47)


def test_uncategorized_transaction_is_accepted(client):
    client.post(
        "/api/transactions",
        json={"transactions": [_transaction("id-1", category=None)]},
        headers=AUTH,
    )
    assert db.get_transaction_by_client_id("id-1")["category"] is None


def test_empty_batch_is_a_no_op(client):
    response = client.post("/api/transactions", json={"transactions": []}, headers=AUTH)
    assert response.json() == {"created": 0, "updated": 0}
