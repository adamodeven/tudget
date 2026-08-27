"""Budget math: spend totals, remaining amounts, and reply summaries.

All budget limits and totals are tracked in the configured default
currency (db stores each transaction's amount_default_currency, converted
at insert time via currency.convert) -- a purchase's own reply line just
happens to show it in whatever currency it was made in.
"""

from __future__ import annotations

from datetime import datetime

import currency
import db


def category_remaining(category: str, monthly_limit: float, now: datetime | None = None) -> tuple[float, float, float]:
    """Returns (spent, limit, remaining) for a category this month, in the
    default currency."""
    now = now or datetime.now()
    spent = db.get_category_spent(category, now.year, now.month)
    return spent, monthly_limit, monthly_limit - spent


def month_totals(categories: list[dict], now: datetime | None = None) -> tuple[float, float, float]:
    """Returns (spent, limit, remaining) across all categories this month,
    in the default currency."""
    now = now or datetime.now()
    total_limit = sum(c["monthly_limit"] for c in categories)
    total_spent = db.get_month_total_spent(now.year, now.month)
    return total_spent, total_limit, total_limit - total_spent


def _amount_line(label: str, remaining: float, limit: float, default_currency: str) -> str:
    if remaining >= 0:
        return f"{label}: {currency.format_amount(remaining, default_currency)} of {currency.format_amount(limit, default_currency)} left."
    return f"{label}: {currency.format_amount(abs(remaining), default_currency)} over your {currency.format_amount(limit, default_currency)} budget."


def format_budget_reply(
    category: str,
    categories: list[dict],
    default_currency: str,
    now: datetime | None = None,
) -> str:
    """Builds the "Going Out: $87 of $200 left. Month total: ..." reply,
    in the default currency."""
    now = now or datetime.now()
    cat_row = next((c for c in categories if c["name"] == category), None)
    cat_limit = cat_row["monthly_limit"] if cat_row else 0.0

    _, _, cat_remaining = category_remaining(category, cat_limit, now)
    _, total_limit, total_remaining = month_totals(categories, now)

    cat_line = _amount_line(category, cat_remaining, cat_limit, default_currency)
    total_line = _amount_line("Month total", total_remaining, total_limit, default_currency)
    return f"{cat_line} {total_line}"
