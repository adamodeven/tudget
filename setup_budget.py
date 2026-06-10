"""Standalone CLI: suggests a budget split using a modified 50/30/20 rule
based on your take-home pay, lets you adjust it interactively, then writes
the confirmed limits to the Notion Categories database.

Run with: python setup_budget.py
"""

from __future__ import annotations

import db
import notion_sync
from config import load_config

# (name, emoji, group, fraction of take-home)
# 50% needs / 30% wants / 20% savings, split across Tudget's categories.
DEFAULT_CATEGORIES = [
    ("Food", "\U0001F354", "needs", 0.30),
    ("Transport", "\U0001F697", "needs", 0.15),
    ("Subscriptions", "\U0001F501", "needs", 0.05),
    ("Going Out", "\U0001F37B", "wants", 0.15),
    ("Shopping", "\U0001F6CD", "wants", 0.10),
    ("Other", "\U0001F9FE", "wants", 0.05),
    ("Savings", "\U0001F4B0", "savings", 0.20),
]

GROUP_LABELS = {
    "needs": "Needs (50%)",
    "wants": "Wants (30%)",
    "savings": "Savings (20%)",
}


def prompt_take_home() -> float:
    while True:
        raw = input("What's your monthly take-home pay? $").strip().replace(",", "").replace("$", "")
        try:
            value = float(raw)
            if value > 0:
                return value
        except ValueError:
            pass
        print("Please enter a positive number, e.g. 4500")


def suggest_limits(take_home: float) -> dict[str, float]:
    return {name: round(take_home * fraction) for name, _, _, fraction in DEFAULT_CATEGORIES}


def print_limits(limits: dict[str, float], take_home: float) -> None:
    print("\nMonthly budget:")
    current_group = None
    for name, emoji, group, _ in DEFAULT_CATEGORIES:
        if group != current_group:
            print(f"\n{GROUP_LABELS[group]}")
            current_group = group
        print(f"  {emoji} {name:<14} ${limits[name]:,.0f}")

    total = sum(limits.values())
    print(f"\nTotal: ${total:,.0f} (take-home: ${take_home:,.0f})")


def review_limits(limits: dict[str, float], take_home: float) -> dict[str, float]:
    limits = dict(limits)
    while True:
        print_limits(limits, take_home)
        choice = input(
            "\nPress Enter to accept, type a category name to change its amount, or 'done' to save: "
        ).strip()

        if choice == "" or choice.lower() == "done":
            return limits

        match = next((name for name, *_ in DEFAULT_CATEGORIES if name.lower() == choice.lower()), None)
        if match is None:
            print(f"Unknown category: {choice!r}")
            continue

        new_value = input(f"New monthly limit for {match} (currently ${limits[match]:,.0f}): $").strip()
        try:
            limits[match] = round(float(new_value.replace(",", "")))
        except ValueError:
            print("Please enter a number.")


def main() -> None:
    config = load_config()

    print("Tudget budget setup")
    print("=" * 40)
    take_home = prompt_take_home()

    limits = suggest_limits(take_home)
    limits = review_limits(limits, take_home)

    print(
        f"\nNote: Savings (${limits['Savings']:,.0f}/mo) is shown for reference only "
        "and isn't written to Notion as a spending category."
    )

    categories = [
        {"name": name, "monthly_limit": limits[name], "emoji": emoji}
        for name, emoji, group, _ in DEFAULT_CATEGORIES
        if group != "savings"
    ]

    print("\nWriting categories to Notion...")
    client = notion_sync.get_notion_client(config)
    notion_sync.upsert_categories(client, config.notion.categories_db_id, categories)

    db.init_db()
    db.replace_categories(notion_sync.fetch_categories(client, config.notion.categories_db_id))

    print("Done. Categories and limits are set in Notion and cached locally.")


if __name__ == "__main__":
    main()
