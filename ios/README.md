# Tudget for iOS

The native app: log purchases by typing a line, or by sharing a screenshot of
a bank notification. Multi-currency, budgets by category, everything stored on
device. No server required.

- **Nothing to run.** SwiftData on device, Vision framework for OCR. The
  Python server in the parent directory is optional (see [Syncing](#optional-syncing-to-the-python-server)).
- **Any currency.** Log `€12,47 lunch` or `1200 JPY ramen`; budgets are tracked
  in your home currency and converted at log time.
- **Share sheet capture.** Screenshot a purchase alert → Share → Tudget. Two
  taps, no app switch.

---

## Build it

### 1. Prerequisites

- A Mac with **Xcode 15 or newer** (iOS 17 SDK — the app uses SwiftData and
  `@Observable`).
- **XcodeGen**: `brew install xcodegen`

The Xcode project is generated from [`project.yml`](project.yml) rather than
committed. That keeps a 20,000-line `pbxproj` out of the repo, and puts the one
thing you have to personalise in a single readable file.

### 2. Set your bundle ID and team

Open `project.yml` and edit the two lines under `settings.base`:

```yaml
settings:
  base:
    APP_BUNDLE_ID: com.yourname.tudget   # must be globally unique
    DEVELOPMENT_TEAM: "ABCDE12345"       # your 10-char Apple Team ID
```

Your Team ID is at [developer.apple.com/account](https://developer.apple.com/account)
→ Membership details. Everything else — the extension's bundle ID, the App
Group, the entitlements — is derived from `APP_BUNDLE_ID`, so this is the only
place you set it.

### 3. Generate and open

```bash
cd ios
xcodegen generate
open Tudget.xcodeproj
```

Select the **Tudget** scheme, pick your device or a simulator, and run.

> Xcode will register the App Group (`group.<your bundle id>`) automatically
> with Automatic signing the first time you build to a device. If it complains,
> open **Signing & Capabilities** on both targets and confirm the same App
> Group is listed on each.

### 4. Run the tests

⌘U in Xcode, or:

```bash
xcodebuild test -project Tudget.xcodeproj -scheme Tudget \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

The suite covers currency parsing, purchase-text extraction, category
matching, and budget math — the logic ported from the Python side, held to the
same expectations as `tests/test_currency.py` and friends.

---

## Ship it to TestFlight

### 1. Create the app record

At [App Store Connect](https://appstoreconnect.apple.com) → **Apps** → **+** →
**New App**:

- Platform: iOS
- Bundle ID: the `APP_BUNDLE_ID` you set above (it appears in the dropdown once
  Xcode has registered it — building to a device once is the easiest way)
- SKU: anything, e.g. `tudget`

### 2. Archive

In Xcode: set the run destination to **Any iOS Device (arm64)** — archiving is
disabled for simulators — then **Product → Archive**.

To bump the build number between uploads, edit `CURRENT_PROJECT_VERSION` in
`project.yml` and re-run `xcodegen generate`. App Store Connect rejects a build
number it has already seen.

### 3. Upload

When the Organizer opens: **Distribute App** → **TestFlight & App Store** →
**Upload**. Accept the defaults for signing.

Or from the command line:

```bash
xcodebuild -project Tudget.xcodeproj -scheme Tudget \
  -destination 'generic/platform=iOS' \
  -archivePath build/Tudget.xcarchive archive

xcodebuild -exportArchive -archivePath build/Tudget.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
```

### 4. Install from TestFlight

Processing takes a few minutes. Then, in App Store Connect → your app →
**TestFlight**, add yourself under **Internal Testing** (any user on your
team can be added instantly — no review needed). Install
[TestFlight](https://apps.apple.com/app/testflight/id899247664) on your phone
and the build shows up.

Internal builds skip Beta App Review entirely, so this is usually minutes, not
days. `ITSAppUsesNonExemptEncryption` is already set to `false` in
`Info.plist`, so you won't be asked about export compliance on every upload.

---

## Using it

**Type a purchase.** Budget tab → *Add purchase* → Quick mode takes a whole
line: `Trader Joe's $34 groceries`. It parses the merchant, amount, currency,
and category live, and shows you what it understood before you commit. Details
mode gives you structured fields, a date picker, and a receipt attachment.

**From a screenshot.** Budget tab → *From screenshot*, pick the notification
screenshot, and Vision reads it on device. What it found comes back as an
editable draft — never saved blind — plus the raw text it read, so a bad parse
is obvious rather than mysterious.

**From the share sheet.** Screenshot a bank alert, hit Share, pick Tudget. The
extension OCRs it, you pick a category, done — the app doesn't even have to be
open. Captures queue in the App Group and land in the ledger the next time you
open the app.

**Categorizing.** Anything logged without a category shows up under *Needs a
category* on the dashboard. Tapping one gives you a grid of categories and,
once you pick, the same "what's left" line the SMS version used to text back:
`Food: $387 of $400 left. Month total: $587 of $600 left.`

---

## A note on automatic capture

The long-term goal was intercepting bank-app notifications automatically.
Worth being clear about where that stands per platform:

**iOS does not allow it.** There is no public API for one app to read another
app's notifications — no equivalent to Android's `NotificationListenerService`.
Shortcuts has no "notification received" trigger either. This isn't a
limitation of the app; nothing on the App Store can do it.

So on iPhone, the realistic paths to "I didn't type this in" are:

1. **The share extension** (built) — screenshot the alert, share it, two taps.
2. **Bank alert emails** (built, server-side) — if your bank can email
   transaction alerts, the Python server's Gmail poller parses them
   automatically and the app pulls them in via sync. This is the closest thing
   to genuine automation on iOS.
3. **Plaid nightly reconciliation** (built, server-side) — catches anything
   missed, once a day.

Options 2 and 3 need the Python server running, which is what the sync setting
below is for. Full push-notification interception remains Android-only.

---

## Optional: syncing to the Python server

The app is complete on its own. Turn sync on if you want the Notion dashboard,
bank-email parsing, or Plaid reconciliation from the server-side Tudget.

**On the server**, in `config.yaml`:

```yaml
messaging:
  channel: "none"        # the app is the front end now; no texting
api:
  enabled: true
  token: "<paste a generated token>"
```

Generate the token with:

```bash
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

**In the app**: Settings → *Sync to my server* → paste your server's public
URL (the ngrok URL) and the same token → *Sync now*.

Sync is a one-way push of anything not yet sent. It never blocks or loses a
purchase: if the server is unreachable, rows stay marked unsynced and go out on
the next attempt. Re-syncing the same purchase updates the existing row rather
than duplicating it — the app's UUID travels with each transaction.

---

## Project layout

```
ios/
  project.yml                    # XcodeGen spec — bundle ID and team live here
  Tudget/
    TudgetApp.swift              # @main, model container
    Core/                        # pure logic, shared with the extension
      Currency.swift             #   symbols, codes, formatting
      CurrencyParser.swift       #   "€12,47" -> (12.47, EUR)
      PurchaseTextParser.swift   #   typed entry + OCR'd notification text
      CategoryMatcher.swift      #   "grub" -> Food, with typo tolerance
      BudgetCalculator.swift     #   spend/remaining/totals
      FXRateService.swift        #   live rates, cached, offline fallback
      VisionOCR.swift            #   screenshot -> text, on device
    Models/                      # SwiftData: Transaction, BudgetCategory
    Views/                       # dashboard, add, history, setup, settings
    Shared/                      # App Group bridge to the extension
    Sync/                        # optional push to the Python server
  TudgetShare/                   # share extension
  TudgetTests/                   # XCTest for everything in Core/
```

`Core/` and `Shared/` compile into both the app and the extension, so parsing
behaviour can't drift between "logged in the app" and "shared from the share
sheet."
