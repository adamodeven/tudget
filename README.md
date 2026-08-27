# Tudget

Tudget. Text budget.

A personal budget tracker built around one idea: logging a purchase should
take two taps, in whatever currency you spent.

There are two ways to run it, and they work together:

### 📱 [The iOS app](ios/) — start here

A native SwiftUI app you install from TestFlight. Type `Trader Joe's $34
groceries`, or share a screenshot of a bank notification straight from the
share sheet and let on-device OCR read it. Budgets by category, any
currency, everything stored on your phone. **No server required.**

→ **[Build and TestFlight instructions](ios/README.md)**

### 💬 The server — texting, Notion, and bank automation

A self-hosted FastAPI service you text (or iMessage) purchases to, with a
Notion dashboard and the two things a phone can't do on its own:

- **Gmail polling** parses bank transaction-alert emails automatically
  (off by default).
- **Plaid** runs a nightly check across linked accounts to catch anything
  email parsing missed (off by default).

Run it alongside the app (set `messaging.channel: "none"` and enable the
API — see [Syncing](ios/README.md#optional-syncing-to-the-python-server)),
or on its own as a pure SMS bot. The rest of this README covers the server.

> **On automatic notification capture:** iOS provides no API for one app to
> read another app's notifications, so full push interception is
> Android-only. On iPhone the share extension covers manual capture, and
> the server's Gmail/Plaid automation covers the rest — details in the
> [app README](ios/README.md#a-note-on-automatic-capture).

## How it works

1. You text (or iMessage) Tudget: `Chipotle $12.47 food`, or just `$12.47
   food` if you're mid-conversation, or a screenshot of a bank push
   notification with no text at all.
2. If a category wasn't recognized in your message, Tudget asks: `Got it —
   $12.47 at Chipotle. Reply with a category (Food / Going Out /
   Transport / Shopping / Subscriptions / Other) and I'll log it.`
3. You reply with a category (typos and synonyms are fine — "grub",
   "eating", "food" all map to **Food**), optionally with a receipt photo
   attached.
4. Tudget updates SQLite, uploads the raw receipt/screenshot as a Notion
   attachment, syncs the transaction + budget summary to Notion in the
   background, and texts back your remaining budget:
   `Food: $387 of $400 left. Month total: $587 of $600 left.`
5. Optionally, turn on Gmail polling and/or Plaid (see below) so Tudget
   texts you the moment a bank alert email or linked-account transaction
   comes in, instead of you starting the conversation.

## Project structure

```
tudget/
  ios/                  # the iOS app — see ios/README.md
  main.py               # FastAPI app, webhooks, background jobs
  api.py                 # optional: JSON API the iOS app syncs into
  inbound.py             # channel-agnostic message handling: category matching,
                          # manual-entry parsing, screenshot handoff to ocr.py
  messaging.py            # picks the Twilio, iMessage, or null client from config
  twilio_client.py        # Twilio SMS/MMS transport (send + download media)
  imessage_client.py      # iMessage transport via BlueBubbles (send + webhook parsing)
  currency.py              # amount/currency parsing, formatting, live FX conversion
  ocr.py                    # screenshot -> {merchant, amount, currency} via OCR
  gmail_poller.py            # optional: polls Gmail, parses bank emails
  bank_parsers.py              # per-bank email body -> {merchant, amount, currency, card}
  notion_sync.py                # reads/writes the three Notion databases
  plaid_client.py                 # optional: nightly reconciliation
  db.py                             # all SQLite operations
  budget.py                         # budget math (spent / remaining / reply text)
  config.py                          # loads + validates config.yaml
  setup_budget.py                     # CLI budget setup tool
  config.yaml                          # gitignored — your real secrets
  config.example.yaml                  # committed — documents every key
  requirements.txt
  tests/                                 # pytest tests for the pure-logic modules
  data/
    tudget.db                             # SQLite database (created automatically)
    receipts/                              # raw receipt/screenshot photos (served at /receipts/...)
    unparsed_emails.log                     # bank emails that matched a sender but didn't parse
```

## Prerequisites

- Python 3.11+
- A [Notion](https://www.notion.so) account + internal integration
- A messaging channel — pick one:
  - A [Twilio](https://www.twilio.com) account with an SMS/MMS-capable
    number (works anywhere, no extra hardware), **or**
  - iMessage via [BlueBubbles](https://bluebubbles.app) (needs a Mac —
    see the [iMessage section](#imessage-setup-instead-of-twilio) before
    picking this)
- [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) — for
  reading screenshots (`brew install tesseract` on macOS, `apt install
  tesseract-ocr` on Debian/Ubuntu)
- [ngrok](https://ngrok.com) to expose your local server to Twilio/BlueBubbles/Notion
- Optional, for automation: a Google account + [Google
  Cloud](https://console.cloud.google.com) project (Gmail alerts), a
  [Plaid](https://dashboard.plaid.com) account (nightly reconciliation)

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

   This is the database you edit to set your budget, in your configured
   `currency.default_currency`. Tudget reads it on startup and refreshes
   every hour (`notion.category_refresh_interval_seconds`).

   **Transactions**
   | Property | Type |
   | --- | --- |
   | Merchant | Title |
   | Amount | Number |
   | Currency | Select |
   | Card | Select |
   | Category | Select |
   | Receipt | Files & media |
   | Timestamp | Date |
   | Reconciled | Checkbox |

   Amount is always the purchase's *original* amount/currency (e.g. a
   €12.47 purchase shows Amount: 12.47, Currency: EUR) — budget totals
   below are converted to your default currency, but the raw transaction
   record isn't.

   **Budget Summary**
   | Property | Type |
   | --- | --- |
   | Category | Title |
   | Spent | Number |
   | Limit | Number |
   | Remaining | Number |
   | % Used | Number (format as "Percent" if you want it to display as a %) |

   These four are always in `currency.default_currency`.

3. For each database, click **Share** → **Connections** and add your
   integration.
4. Open each database as a full page and copy the 32-character ID out of
   the URL (`notion.so/yourworkspace/<DATABASE_ID>?v=...`) into
   `config.yaml` under `notion.categories_db_id`,
   `notion.transactions_db_id`, and `notion.budget_summary_db_id`.

---

## 3. Pick a messaging channel

Set `messaging.channel` in `config.yaml` to `"twilio"`, `"imessage"`, or
`"none"`.

### No messaging (the iOS app is your front end)

If you're using [the app](ios/), the server doesn't need to text you at all
— it just needs to accept purchases from the app and keep Notion, Gmail
parsing, and Plaid running behind it:

```yaml
messaging:
  channel: "none"
api:
  enabled: true
  token: "<generate one, see below>"
```

```bash
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

Then put the same URL and token into the app under Settings → *Sync to my
server*. The API exposes `GET /api/health`, `GET /api/categories`, and
`POST /api/transactions`, all behind that bearer token. Transactions carry
the app's own UUID, so re-syncing updates rather than duplicates. Skip the
Twilio and iMessage sections below.

### Twilio setup (SMS/MMS)

1. Create a Twilio account and buy a phone number with SMS + MMS support.
2. Copy the **Account SID** and **Auth Token** from the
   [Twilio console](https://console.twilio.com) into `config.yaml` under
   `twilio`.
3. Put the Twilio number into `twilio.from_number` and your own phone
   number (E.164, e.g. `+15555550123`) into `phone.my_number`. Only texts
   from `phone.my_number` are processed — everything else is ignored.
4. Once ngrok is running (step 6), point the number's webhook at
   `https://<your-ngrok-url>/sms` as the **"A message comes in"** webhook
   (HTTP POST).

### iMessage setup (instead of Twilio)

A personal Apple Developer Program membership ($99/year) does **not**, on
its own, grant access to any API for sending/receiving iMessage. Apple's
only official programmatic channel is *Messages for Business* (Business
Chat), which requires enrolling as a business through Apple Business
Register and getting approved — it's built for companies messaging
customers at scale, and that approval isn't available to individual
developer accounts, so there's no route from "I have an Apple Developer
plan" to "I can call an Apple API to send myself iMessages."

The practical, widely-used way to run a personal iMessage bot is
[BlueBubbles](https://bluebubbles.app) (open source, free): a small server
you run on a Mac that's signed into Messages.app with an Apple ID — a
spare Mac mini or old MacBook works, as does a rented cloud Mac (an AWS
EC2 Mac instance or MacStadium). BlueBubbles exposes a REST API to send
messages and a webhook to receive them, which is what `imessage_client.py`
talks to. Use a dedicated "bot" Apple ID for that Mac's Messages.app
rather than your personal one, and text it from your own number.

1. Install BlueBubbles Server on a Mac that's always on and signed into
   Messages.app: <https://bluebubbles.app/install/>
2. In BlueBubbles Server settings, set a server password and note its
   local address (or a Tailscale/ngrok URL to it).
3. Once Tudget is running and ngrok (or your tunnel) is up, add a webhook
   in BlueBubbles (Settings → API & Webhooks) pointing at
   `<your base_url>/imessage/webhook` for the **New Message** event.
4. Fill in `config.yaml`:
   ```yaml
   messaging:
     channel: "imessage"
   imessage:
     server_url: "http://localhost:1234"   # or your tunnel to the Mac
     password: "your-bluebubbles-server-password"
     my_handle: "+15555550123"             # your phone number/Apple ID — only texts from this are processed
   ```

If you'd rather not run a Mac 24/7, Twilio is the simpler path and works
identically from the user's side (text in, text back).

---

## 4. Set your default currency

```yaml
currency:
  default_currency: "USD"
```

This is the currency your budget limits and totals are tracked in.
Purchases in any other currency are accepted the same way — `€12,47
lunch`, `£8.50 coffee`, a screenshot of a JPY transaction — Tudget detects
the currency from a symbol (`$ € £ ¥ ₹ ...`) or a 3-letter code (`EUR`,
`GBP`, ...) in the text, or falls back to `default_currency` if none is
present. The original amount + currency is stored and shown as-is; budget
math converts it to `default_currency` using a live rate from
[frankfurter.app](https://www.frankfurter.app) (cached for an hour, with a
static fallback table if that API is unreachable).

---

## 5. Run the server

```bash
source .venv/bin/activate
uvicorn main:app --host 0.0.0.0 --port 8000
```

In another terminal, keep ngrok running:

```bash
ngrok http 8000
```

Copy the `https://...ngrok-free.app` URL into `config.yaml` under
`server.base_url` — it's used for the inbound webhook (if you haven't set
it yet, do so now and point Twilio/BlueBubbles at it) and to build the
public link to receipt/screenshot photos embedded in the Notion
Transactions record, so ngrok needs to stay running for those image
embeds to load.

Check `http://localhost:8000/health` to confirm it's up. At this point
Tudget is fully usable via manual text/screenshot entry — Gmail and Plaid
below are optional.

---

## 6. Set your budget

```bash
python setup_budget.py
```

This asks for your monthly take-home pay (in `currency.default_currency`),
suggests a budget split using a modified 50/30/20 rule (50% needs, 30%
wants, 20% savings — broken down across Food/Transport/Subscriptions/Going
Out/Shopping/Other, with Savings shown for reference only), lets you
adjust any category interactively, and writes the confirmed limits to the
Notion Categories database.

---

## 7. Optional: Gmail polling (real-time bank-email detection)

Off by default (`gmail.enabled: false`) — this automates step 1 of the
flow above (Tudget starts the conversation instead of you) by watching for
bank transaction-alert emails. Skip this whole section if you're happy
texting/screenshotting purchases in yourself.

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
5. Fill in `bank_senders` in `config.yaml` for whichever banks you use,
   and set `gmail.enabled: true`.

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
`data/unparsed_emails.log` — use that to adjust the `MERCHANT_RE` pattern
(or add a bank-specific tweak) to match what your bank actually sends.

---

## 8. Optional: Plaid (nightly reconciliation)

Off by default (`plaid.enabled: false`) — this is a safety net that
catches anything email parsing missed, not required for Tudget to work.

1. Create a [Plaid](https://dashboard.plaid.com) account and grab your
   **sandbox** `client_id` and `secret`.
2. Use Plaid's Quickstart / Link in sandbox mode to link test accounts for
   each of your banks (sandbox credentials are `user_good` / `pass_good`
   for any institution).
3. Exchange the resulting `public_token` for an `access_token`
   (`/item/public_token/exchange`), then call `/accounts/get` to find the
   `account_id` for each account.
4. Add one entry per account under `plaid.accounts` in `config.yaml`, and
   set `plaid.enabled: true`:

   ```yaml
   plaid:
     enabled: true
     environment: "sandbox"
     accounts:
       - name: "Chase Credit"
         access_token: "access-sandbox-..."
         account_id: "..."
   ```

   When you're ready for real data, switch `plaid.environment` to
   `production` and re-link with real institution credentials. Plaid
   reports each transaction's own currency (`iso_currency_code`), which is
   converted to `currency.default_currency` the same way as any other
   purchase.

To run the nightly job on demand (useful for testing) instead of waiting
for `plaid.reconciliation_hour`:

```bash
curl -X POST http://localhost:8000/reconcile
```

---

## Manual entry examples

Texting Tudget when you *don't* have a pending categorization (i.e. you're
not replying to a "reply with category" prompt) logs a new transaction.
These all work:

- `Trader Joe's $34 groceries` → Food, merchant "Trader Joe's"
- `CVS $8.50 health` → amount + merchant "CVS health" recognized, asks for
  a category since "health" isn't one
- `$12 coffee going out` → Going Out, merchant "coffee"
- `Cafe Luna €12,47 food` → Food, merchant "Cafe Luna", logged as €12.47
  (converted to your default currency for budget totals)
- A screenshot of a bank/payment-app purchase notification, with no text
  — Tudget OCRs it for the amount, currency, and merchant, and asks you to
  categorize like any other new transaction. If it can't read an amount
  off it, it asks you to type the merchant and amount instead.
- A photo with no text and no amount Tudget can OCR → *"Got the
  screenshot, but I couldn't read an amount off it — what was the
  merchant and amount?"*
- Missing the amount or merchant → Tudget asks for whichever piece is
  missing.
- If no category is recognized, Tudget logs the transaction and asks you
  to reply with one from your category list — same as a normal alert.

## Currency notes

- Any amount with a recognizable symbol (`$ € £ ¥ ₹ ₩ ₺ ₽ ₴ ₫ ฿ ₱` and a
  few multi-character ones like `C$`, `A$`, `HK$`) or a 3-letter ISO code
  (`EUR`, `GBP`, `CHF`, ...) either before or after the number is
  recognized; a bare number falls back to `currency.default_currency`.
- Both `12,47` (European decimal comma) and `1,234.56` /
  `1.234,56` (thousands-separated) formats are handled.
- FX rates are fetched live from frankfurter.app and cached for an hour;
  if that's unreachable, a small built-in approximate-rate table is used
  instead (logged as a warning) so budget math never just breaks.
