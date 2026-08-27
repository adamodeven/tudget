# Tudget ingest server

**You don't need this.** The iOS app is complete on its own and never contacts
it. This is scaffolding, parked for one future job.

## What it's for

iOS gives no app permission to read another app's notifications — there's no
equivalent of Android's `NotificationListenerService`, and Shortcuts has no
"notification received" trigger. Nothing on the App Store can intercept your
bank's purchase alerts.

The plan for genuinely automatic capture therefore runs through an Android
phone:

```
Android notification listener   ->   POST /api/transactions   ->   SQLite
                                                                     |
                                     GET /api/transactions  <--------+
                                     POST /api/transactions/claim
                                                |
                                        Tudget on iOS pulls,
                                        asks you to categorize
```

The Android app doesn't exist yet, and neither does the pull side in iOS.
What's here is the middle: somewhere to put an intercepted notification, and
somewhere to read it back from exactly once.

## What it deliberately isn't

The previous version of this server did Twilio SMS, iMessage, Gmail alert
parsing, Plaid reconciliation, tesseract OCR, and Notion sync. All of it is
gone — those jobs either moved into the app (OCR, budgets, categories,
history) or were dropped. It's in the git history if you want it:

```bash
git show origin/ios:main.py
```

## Running it

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

cp config.example.yaml config.yaml
python -c "import secrets; print(secrets.token_urlsafe(32))"   # paste into config.yaml

uvicorn app:app --host 0.0.0.0 --port 8000
```

`config.yaml` is gitignored. Every endpoint requires
`Authorization: Bearer <token>`.

## Endpoints

| Method | Path | Who calls it |
| --- | --- | --- |
| `GET` | `/api/health` | anything; also reports how many are unclaimed |
| `POST` | `/api/transactions` | the Android listener, on each intercepted alert |
| `GET` | `/api/transactions` | the app, to pull what it hasn't seen |
| `POST` | `/api/transactions/claim` | the app, to say "I've taken these" |

`POST /api/transactions` takes a client-generated `uuid` and upserts on it, so
a retry after a flaky response updates the same row rather than creating a
duplicate purchase.

```bash
curl -X POST localhost:8000/api/transactions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
        "uuid": "11111111-2222-3333-4444-555555555555",
        "merchant": "Chipotle",
        "amount": 12.47,
        "currency_code": "USD",
        "raw_text": "You spent $12.47 at CHIPOTLE 1234",
        "source_app": "com.chase.sig.android"
      }'
```

## Note on exposing it

If you do run this, it needs to be reachable from the Android phone. A
tunnel (`ngrok http 8000`) or a private network such as Tailscale both work;
Tailscale is the better choice for something holding your purchase history,
since it isn't on the public internet at all.
