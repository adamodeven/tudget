# Tudget

Tudget. Text budget.

A self-hosted budget tracker that watches your bank apps' push
notifications in real time (via a tethered Android relay device), texts
you after every purchase, and lets you categorize by replying to that text
(with an optional receipt photo). Notion is your dashboard and budget
config. Plaid runs a nightly check to catch anything notification parsing
missed. No AI, no OCR — just regex, SQLite, and fuzzy string matching.

## How it works

1. A spare Android phone, tethered to the server over USB and signed into
   your Chase, SoFi, Fidelity, and Venmo apps, forwards every bank app
   notification to Tudget's `/notification` endpoint the instant it
   arrives. Tudget parses out the merchant, amount, and card.
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
   accounts and texts you a summary of anything notification parsing
   missed.

## Project structure

```
tudget/
  main.py              # FastAPI app, routes, background jobs
  notification_parsers.py # per-bank push-notification text -> {merchant, amount, card} parsers
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
  Dockerfile
  docker-compose.yml      # app + optional ngrok and android-watchdog sidecars
  .env.example            # NGROK_AUTHTOKEN / FORWARDER_PACKAGE for optional services
  watchdog/
    Dockerfile            # adb-based watchdog image for the android-watchdog service
    watchdog.sh            # keeps the relay device's forwarder app alive
    android/                # gitignored — persists the adb key pair
  data/
    tudget.db             # SQLite database (created automatically)
    receipts/             # raw receipt photos (served at /receipts/...)
    unparsed_notifications.log # bank notifications that matched an app but didn't parse
```

## Prerequisites

- Python 3.11+ (or Docker, see step 8)
- A spare Android phone for the notification relay, plus a USB cable that
  supports data transfer (not charge-only) — see device recommendations in
  step 3
- A [Notion](https://www.notion.so) account + internal integration
- A [Twilio](https://www.twilio.com) account with an SMS/MMS-capable number
- A [Plaid](https://dashboard.plaid.com) account (sandbox is fine to start)
- [ngrok](https://ngrok.com) to expose your local server to Twilio/Notion
  and the relay device

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

A local Python environment is needed to run `setup_budget.py` (step 7),
even if you run the server itself with Docker.

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

## 3. Android relay device setup (real-time transaction detection)

Chase, Fidelity, SoFi, and Venmo don't all support email or SMS purchase
alerts, but they all support **push notifications** the instant a card is
charged. Tudget reads those notifications off a dedicated Android device
that's tethered to your server over USB, via a small "notification
forwarder" app that POSTs each bank notification to Tudget's
`/notification` endpoint.

This needs to be a real device — software emulators fail the Play
Integrity checks banking apps require, and attempting to bypass that risks
a fraud hold on your real accounts.

### Device suggestion

You don't need anything fancy — a cheap, **Play Protect certified**
Android phone that can stay plugged in 24/7 works great as a dedicated
relay:

- A used/refurbished **Google Pixel** (4a/5a/6a) — stock Android, long
  software support, cheap secondhand.
- A budget **Samsung Galaxy A-series** (A13/A14/A15) — new for roughly
  $100-150, Play Protect certified.

What matters when picking a device:

- **Play Protect certified** — check
  [android.com/certified](https://www.android.com/certified/partners/).
  Uncertified devices (most generic Android boxes/tablets) fail Play
  Integrity, so the bank apps will refuse to install or log in.
- A USB port and cable that support **data**, not just charging — some
  cables and phone-charger USB ports are power-only and won't work for
  `adb`.
- 32GB of storage is plenty for the four bank apps plus the forwarder app.

Avoid emulators, Android TV boxes, and "Android tablet" knockoffs without
Google Play — banking apps won't run on them.

### Set up the device

1. Go through normal first-time setup (Google account, etc.), then install
   the Chase, Fidelity, SoFi, and Venmo apps and log into each.
2. Install a notification-forwarder app that can make an HTTP request when
   a notification arrives —
   [MacroDroid](https://play.google.com/store/apps/details?id=com.arlosoft.macrodroid)
   (free tier covers this) is recommended.
3. In MacroDroid, create one macro per bank app:
   - **Trigger**: *Notification Received* → select the bank app, and
     enable *"Trigger only if notification content has changed"* (avoids
     re-firing on duplicate/updated notifications).
   - **Action**: *HTTP Request*:
     - Method: `POST`
     - URL: `https://<your-ngrok-url>/notification` (your ngrok URL from
       step 6)
     - Headers: `X-Tudget-Secret: <notification.shared_secret>`,
       `Content-Type: application/json`
     - Body (JSON), using MacroDroid's notification variables:
       ```json
       {"package": "[nfPackage]", "title": "[nfTitle]", "text": "[nfText]"}
       ```
4. Set `notification.shared_secret` in `config.yaml` to a random string
   (e.g. `python -c "import secrets; print(secrets.token_hex(24))"`) and
   use the same value in the MacroDroid header above.
5. Check `notification.apps` in `config.yaml` — the defaults in
   `config.example.yaml` match each bank app's current Play Store package
   name, but double check yours (on most Android versions, **Settings →
   Apps → [bank app] → Advanced** shows the package name).
6. Plug the device into the server with a USB **data** cable, enable
   **Developer Options** (Settings → About phone → tap "Build number" 7
   times), then enable **USB debugging** and accept the "Allow USB
   debugging" prompt on the device, checking "Always allow from this
   computer".
7. Also in Developer Options, enable **Stay awake** (keeps the screen on
   while charging) so Android doesn't suspend the forwarder app's
   notification listener.

### Keeping the relay reliable: the watchdog container

Android's battery optimization (Doze) can still kill background apps,
including notification listeners, even with "Stay awake" on. The optional
`android-watchdog` Docker service manages this over `adb`: it whitelists
the forwarder app from battery optimization and relaunches it if it's been
killed.

```bash
docker compose --profile android-watchdog up -d --build
```

USB device passthrough means this service runs with elevated Docker
permissions (`privileged: true` — see `docker-compose.yml`). If your
forwarder app isn't MacroDroid, copy `.env.example` to `.env` and set
`FORWARDER_PACKAGE` to its package name.

### Tuning the notification parsers

`notification_parsers.py` uses simple regexes for the common "$X.XX at
MERCHANT" phrasing. If a real notification doesn't parse, it'll be logged
to `data/unparsed_notifications.log` — use that to adjust the
`AMOUNT_RE`/`MERCHANT_RE` patterns (or add a bank-specific tweak) to match
what your bank's app actually sends.

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
This is also the URL you point the Android relay device's notification
forwarder at (step 3), with `/notification` instead of `/sms`.

`server.base_url` is also used to build the public link to receipt photos
that gets attached to the Notion Transactions record, so ngrok needs to
stay running for those image embeds to load.

If you're running with Docker, you can use the bundled `ngrok` service
instead (see step 8) — either way, you need the resulting URL in
`config.yaml` *before* starting the server, and in Twilio's webhook config.

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

By the time you get here, `config.yaml` should exist in the project root.

### Option A: Python venv

```bash
source .venv/bin/activate
uvicorn main:app --host 0.0.0.0 --port 8000
```

In another terminal, keep ngrok running:

```bash
ngrok http 8000
```

### Option B: Docker

```bash
docker compose up --build
```

This builds the image and runs the server with `config.yaml` and `data/`
mounted from the project root so your database and receipts persist across
restarts.

To also run ngrok in a sidecar container, copy `.env.example` to `.env`,
set `NGROK_AUTHTOKEN`, then:

```bash
docker compose --profile ngrok up --build
```

Check `http://localhost:4040` for your public ngrok URL — put it in
`config.yaml`'s `server.base_url` and Twilio's webhook config, then restart
(`docker compose restart tudget`) so the app picks up the new `base_url`.

To also run the Android relay watchdog (step 3), add the
`android-watchdog` profile:

```bash
docker compose --profile ngrok --profile android-watchdog up --build
```

---

On startup (either option), Tudget loads your categories from Notion, then
starts two background loops: an hourly Notion category refresh and the
nightly Plaid reconciliation scheduler. Bank app notifications arrive via
the `/notification` webhook (no polling involved).

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
transactions notification parsing missed (syncing them to Notion), and
texts you a summary.

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
