"""Nightly reconciliation: pulls the last 24h of transactions from Plaid
across all configured accounts, cross-references them against SQLite by
amount + merchant + date, and texts a summary of anything email parsing
missed.

Matched transactions are marked reconciled in SQLite (and in Notion, if
they'd already been categorized and synced). Missed transactions are
inserted as new, uncategorized, reconciled transactions and synced to
Notion so they show up on the dashboard for the user to categorize by hand.
"""

from __future__ import annotations

from datetime import date, timedelta

import plaid
from plaid.api import plaid_api
from plaid.model.transactions_get_request import TransactionsGetRequest
from plaid.model.transactions_get_request_options import TransactionsGetRequestOptions

import db
import notion_sync
from config import AppConfig

_ENVIRONMENTS = {
    "sandbox": getattr(plaid.Environment, "Sandbox", None),
    "development": getattr(plaid.Environment, "Development", None),
    "production": getattr(plaid.Environment, "Production", None),
}


def get_plaid_client(config: AppConfig) -> plaid_api.PlaidApi:
    host = _ENVIRONMENTS.get(config.plaid.environment.lower()) or plaid.Environment.Sandbox
    configuration = plaid.Configuration(
        host=host,
        api_key={"clientId": config.plaid.client_id, "secret": config.plaid.secret},
    )
    api_client = plaid.ApiClient(configuration)
    return plaid_api.PlaidApi(api_client)


def _receipt_url(txn: dict, config: AppConfig) -> str | None:
    if not txn["receipt_path"]:
        return None
    return f"{config.server.base_url.rstrip('/')}/receipts/{txn['receipt_path']}"


def run_reconciliation(config: AppConfig, twilio_client) -> dict:
    plaid_client = get_plaid_client(config)
    notion = notion_sync.get_notion_client(config)

    end_date = date.today()
    start_date = end_date - timedelta(days=1)

    matched_count = 0
    missed: list[dict] = []

    for account in config.plaid.accounts:
        request = TransactionsGetRequest(
            access_token=account.access_token,
            start_date=start_date,
            end_date=end_date,
            options=TransactionsGetRequestOptions(account_ids=[account.account_id]),
        )
        response = plaid_client.transactions_get(request)

        for plaid_txn in response["transactions"]:
            amount = float(plaid_txn["amount"])
            merchant = plaid_txn["merchant_name"] or plaid_txn["name"]
            txn_date = str(plaid_txn["date"])

            match = db.find_matching_transaction(amount, merchant, txn_date)
            if match:
                matched_count += 1
                if not match["reconciled"]:
                    db.mark_reconciled(match["id"])
                    if match["notion_page_id"]:
                        updated = db.get_transaction(match["id"])
                        notion_sync.update_transaction_page(
                            notion, match["notion_page_id"], updated, _receipt_url(updated, config)
                        )
                continue

            transaction_id = db.insert_transaction(
                merchant=merchant,
                amount=amount,
                card=account.name,
                timestamp=f"{txn_date}T00:00:00",
                source="plaid",
                reconciled=True,
            )
            missed_txn = db.get_transaction(transaction_id)
            page_id = notion_sync.create_transaction_page(
                notion, config.notion.transactions_db_id, missed_txn, None
            )
            db.update_transaction(transaction_id, notion_page_id=page_id)
            missed.append(missed_txn)

    if missed:
        lines = "\n".join(f"- {m['card']}: {m['merchant']} ${m['amount']:.2f}" for m in missed)
        message = f"Nightly check found {len(missed)} transaction(s) email parsing missed:\n{lines}"
    else:
        message = f"Nightly check: all caught up, {matched_count} transaction(s) verified."

    twilio_client.send_sms(config.phone.my_number, message)

    return {"matched": matched_count, "missed": len(missed), "message": message}
