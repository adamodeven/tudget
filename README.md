# Tudget

Tudget. Track your budget.

A native iOS budget tracker built around one idea: logging a purchase should
take two taps, in whatever currency you spent, and the app should tell you
whether you can afford the next one.

Everything lives on your phone. There's no account, no server to run, and
nothing to sign into.

## What it does

**Capture, in roughly the time it takes to put your card away**

- **Control Centre button** — swipe down, tap, type `Trader Joe's $34 groceries`.
  The merchant, amount, currency, and category are parsed as you type.
- **Share a screenshot** — screenshot the bank's push notification, hit Share,
  pick Tudget. On-device OCR reads the amount, you tap a category, done. The
  app never has to be opened.
- **The bar above the tab bar** — always there, on every screen, one tap from
  a logged purchase.
- **Home & Lock Screen widgets** — what's left this cycle, and a tap goes
  straight to entry.

Anything logged without a category waits under *Needs a category* rather than
blocking you at the till — the same trick the old SMS version used.

**Staying on budget**

- A **fortnightly cycle** anchored to a Monday, because a month is too long a
  window to extrapolate from while you're spending. Weekly and monthly are
  there too.
- A **pace chart** that projects your current burn rate to the end of the
  cycle and names the day you'd run out: *"At $61/day you run out on Thursday
  3 Sep — 4 days early."*
- **Alerts** when a category crosses your warning threshold, and one when your
  overall pace would run you dry early. Once per category per cycle, so they
  stay worth reading.

**Multi-currency**

Log `€12,47 lunch` or `1200 JPY ramen`. The original amount and currency are
stored as-is and converted into your home currency at the moment you log it,
so a later FX move never rewrites what a past purchase cost you. Rates come
from [frankfurter.app](https://www.frankfurter.app), cached, with an offline
fallback table so logging never fails because the network is down.

---

## Getting it on your phone

See **[ios/README.md](ios/README.md)** for the build and install steps.

Short version:

```bash
brew install xcodegen
cd ios
xcodegen generate
open Tudget.xcodeproj
```

Set your team in [`ios/project.yml`](ios/project.yml), pick your device, hit
run.

---

## Repository layout

```
tudget/
  ios/            the app — see ios/README.md
  server/         optional, parked — see server/README.md
```

### `server/` — parked, not needed

iOS gives no app permission to read another app's notifications; there's no
equivalent of Android's `NotificationListenerService`, and Shortcuts has no
"notification received" trigger. Nothing on the App Store can do it.

So the plan for genuinely automatic capture runs through an Android phone: a
notification listener there intercepts the bank alert and POSTs it to
[`server/`](server/), and Tudget pulls it down and asks you to categorize it.

That Android app doesn't exist yet. The server is scaffolding for when it
does — three endpoints, one bearer token, one SQLite table. **The iOS app is
complete without it and never contacts it.**

The previous Twilio / Gmail / Plaid / Notion server has been removed
entirely. It's still in the history if you want it back:

```bash
git show origin/ios:main.py
```

## Tests

```bash
cd ios
xcodebuild test -project Tudget.xcodeproj -scheme Tudget \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

62 tests covering currency parsing, purchase-text extraction, category
matching, the fortnightly period maths, and the pace projection.
