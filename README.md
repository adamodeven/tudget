# Tudget

Tudget. Text budget.

A self-hosted budget tracker that watches your bank transaction-alert
emails in real time, texts you after every purchase, and lets you
categorize by replying to that text (with an optional receipt photo).
Notion is your dashboard and budget config. Plaid runs a nightly check to
catch anything email parsing missed. No AI, no OCR — just regex, SQLite,
and fuzzy string matching.

## How it works

1. **Gmail polling** (every 60s by default) checks for new transaction
   alert emails from Chase, SoFi, Fidelity, and Venmo, and parses out the
   merchant, amount, and card.
2. Tudget texts you: `Chase: Chipotle $12.47 — reply with category (Food /
   Going Out / Transport / Shopping / Subscriptions / Other) and optionally
   attach a receipt photo`.
3. You reply with a category (typos and synonyms are fine — "grub",
   "eating", "food" all map to **Food**), optionally with a photo of the
   receipt attached.
4. Tudget updates SQLite, uploads the raw receipt photo (if any) as a
   Notion attachment, syncs the transaction + budget summary to Notion in
   the background, and texts back your remaining budget:
   `Going Out: $87 of $200 left. Month total: $340 of $1,200 left.`
5. You can also text Tudget out of the blue — `"CVS $8.50 health"` or
   `"$12 coffee going out"` — and it'll log it as a manual transaction.
6. Every night at 2am, Plaid pulls the last 24h of transactions across all
   accounts and texts you a summary of anything email parsing missed.

## Project structure

```
tudget/
  main.py              # FastAPI app, routes, background jobs
  gmail_poller.py       # polls Gmail, parses bank emails, triggers the SMS flow
  bank_parsers.py        # per-bank email body -> {merchant, amount, card} parsers
  twilio_client.py      # send/receive MMS, category fuzzy-matching, manual entry parsing
  notion_sync.py        # reads/writes the three Notion databases
  plaid_client.py       # nightly reconciliation
  db.py                  # all SQLite operations
  budget.py              # budget math (spent / remaining / SMS summaries)
  config.py              # loads + validates config.yaml
  setup_budget.py        # CLI budget setup tool
  config.yaml            # gitignored — your real secrets
  config.example.yaml    # committed — documents every required key
  requirements.txt
  data/
    tudget.db             # SQLite database (created automatically)
    receipts/             # raw receipt photos (served at /receipts/...)
    unparsed_emails.log    # bank emails that matched a sender but didn't parse
```

## Prerequisites

- Python 3.11+
- A [Notion](https://www.notion.so) account + internal integration
- A [Twilio](https://www.twilio.com) account with an SMS/MMS-capable number
- A [Plaid](https://dashboard.plaid.com) account (sandbox is fine to start)
- A Google account + [Google Cloud](https://console.cloud.google.com) project for Gmail API access
- [ngrok](https://ngrok.com) to expose your local server to Twilio/Notion

---

## 1. Install

```bash
git clone <your fork of this repo>
cd tudget
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp config.example.yaml config.yaml
```

You'll fill in `config.yaml` as you go through the steps below. **Never
commit `config.yaml`** — it's gitignored on purpose.

---

## 2. Notion setup

1. Create an internal integration at
   [notion.so/my-integrations](https://www.notion.so/my-integrations) and
   copy its API key into `config.yaml` under `notion.api_key`.
2. Create three databases (as full-page databases, anywhere in your
   workspace) with exactly these properties:

   **Categories**
   | Property | Type |
   | --- | --- |
   | Name | Title |
   | Monthly Limit | Number |
   | Emoji | Text |

   This is the database you edit to set your budget. Tudget reads it on
   startup and refreshes every hour (`notion.category_refresh_interval_seconds`).

   **Transactions**
   | Property | Type |
   | --- | --- |
   | Merchant | Title |
   | Amount | Number |
   | Card | Select |
   | Category | Select |
   | Receipt | Files & media |
   | Timestamp | Date |
   | Reconciled | Checkbox |

   **Budget Summary**
   | Property | Type |
   | --- | --- |
   | Category | Title |
   | Spent | Number |
   | Limit | Number |
   | Remaining | Number |
   | % Used | Number (format as "Percent" if you want it to display as a %) |

3. For each database, click **Share** → **Connections** and add your
   integration.
4. Open each database as a full page and copy the 32-character ID out of
   the URL (`notion.so/yourworkspace/<DATABASE_ID>?v=...`) into
   `config.yaml` under `notion.categories_db_id`,
   `notion.transactions_db_id`, and `notion.budget_summary_db_id`.

---

## 3. Gmail setup (real-time transaction detection)

1. Go to [console.cloud.google.com](https://console.cloud.google.com),
   create a project, and enable the **Gmail API**.
2. Configure the **OAuth consent screen** (External is fine — add your own
   Google account as a test user) with the `gmail.readonly` scope.
3. Create an **OAuth client ID** of type **Desktop app**, download the
   JSON, and save it as `credentials.json` in the project root (path is
   configurable via `gmail.credentials_file`).
4. Run the one-time interactive auth (opens a browser, asks you to sign in
   and consent):

   ```bash
   python gmail_poller.py
   ```

   This writes `token.json`, which the server reuses (and refreshes
   automatically) afterwards.

### Enabling transaction alerts in each bank

Bank alert wording and menu paths change over time — after enabling these,
send yourself a test purchase and check the **From** address against
`config.yaml`'s `bank_senders` section, adjusting if needed.

- **Chase**: Profile & Settings → Alerts → turn on transaction alerts for
  "every transaction" on your credit card, delivered by email.
- **SoFi**: Settings → Notifications → enable purchase/transaction email
  alerts for both your Credit Card and Checking (debit) account.
- **Fidelity**: Profile → Alerts → set up an "Account activity" alert for
  debit card transactions, delivered by email.
- **Venmo (Credit Card by Synchrony)**: Account settings → Notifications →
  enable purchase alert emails.

### Tuning the email parsers

`bank_parsers.py` uses simple regexes for the common "$X.XX at MERCHANT"
phrasing. If a real alert email doesn't parse, it'll be logged to
`data/unparsed_emails.log` — use that to adjust the `MERCHANT_RE`/`AMOUNT_RE`
patterns (or add a bank-specific tweak) to match what your bank actually
sends.

---

## 4. Twilio setup (two-way MMS)

1. Create a Twilio account and buy a phone number with SMS + MMS support.
2. Copy the **Account SID** and **Auth Token** from the
   [Twilio console](https://console.twilio.com) into `config.yaml`.
3. Put the Twilio number into `twilio.from_number` and your own phone
   number (E.164, e.g. `+15555550123`) into `phone.my_number`. Only texts
   from `phone.my_number` are processed — everything else is ignored.
4. You'll point the number's webhook at your ngrok URL in step 6.

---

## 5. Plaid setup (nightly reconciliation)

1. Create a [Plaid](https://dashboard.plaid.com) account and grab your
   **sandbox** `client_id` and `secret`.
2. Use Plaid's Quickstart / Link in sandbox mode to link test accounts for
   each of your banks (sandbox credentials are `user_good` / `pass_good`
   for any institution).
3. Exchange the resulting `public_token` for an `access_token`
   (`/item/public_token/exchange`), then call `/accounts/get` to find the
   `account_id` for each account.
4. Add one entry per account under `plaid.accounts` in `config.yaml`, e.g.:

   ```yaml
   plaid:
     environment: "sandbox"
     accounts:
       - name: "Chase Credit"
         access_token: "access-sandbox-..."
         account_id: "..."
   ```

   When you're ready for real data, switch `plaid.environment` to
   `production` and re-link with real institution credentials.

---

## 6. ngrok setup

```bash
# install (macOS example)
brew install ngrok

ngrok config add-authtoken <your authtoken>
ngrok http 8000
```

Copy the `https://...ngrok-free.app` URL into `config.yaml` under
`server.base_url`, and set it as the **"A message comes in"** webhook (HTTP
POST) for your Twilio number, pointing at `https://<your-ngrok-url>/sms`.

`server.base_url` is also used to build the public link to receipt photos
that gets attached to the Notion Transactions record, so ngrok needs to
stay running for those image embeds to load.

---

## 7. Set your budget

```bash
python setup_budget.py
```

This asks for your monthly take-home pay, suggests a budget split using a
modified 50/30/20 rule (50% needs, 30% wants, 20% savings — broken down
across Food/Transport/Subscriptions/Going Out/Shopping/Other, with Savings
shown for reference only), lets you adjust any category interactively, and
writes the confirmed limits to the Notion Categories database.

---

## 8. Run the server

```bash
source .venv/bin/activate
uvicorn main:app --host 0.0.0.0 --port 8000
```

In another terminal, keep ngrok running:

```bash
ngrok http 8000
```

On startup, Tudget loads your categories from Notion, then starts three
background loops: the Gmail poller, an hourly Notion category refresh, and
the nightly Plaid reconciliation scheduler.

Check `http://localhost:8000/health` to confirm it's up.

---

## 9. Trigger nightly reconciliation manually

The nightly job normally runs automatically at `plaid.reconciliation_hour`
(2am by default). To run it on demand (useful for testing):

```bash
curl -X POST http://localhost:8000/reconcile
```

This fetches the last 24h of Plaid transactions for every configured
account, marks matching SQLite transactions as reconciled, inserts any
transactions email parsing missed (syncing them to Notion), and texts you
a summary.

---

## Manual entry examples

Texting the Tudget number when you *don't* have a pending categorization
(i.e. you're not replying to a transaction alert) logs a manual entry.
These all work:

- `Trader Joe's $34 groceries` (+ photo) → Food, merchant "Trader Joe's"
- `CVS $8.50 health`
- `$12 coffee going out`
- A photo with no text → Tudget asks: *"Got the receipt — what was the
  merchant and amount?"*
- Missing the amount or merchant → Tudget asks for whichever piece is
  missing.
- If no category is recognized, Tudget logs the transaction and asks you
  to reply with one from your category list — same as a normal alert.
