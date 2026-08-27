# Tudget for iOS

SwiftUI, SwiftData, iOS 26. Everything on device.

---

## Build it

### 1. Prerequisites

- A Mac with **Xcode 26** or newer (iOS 26 SDK — the app uses Liquid Glass,
  `ControlWidget`, and SwiftData).
- **XcodeGen**: `brew install xcodegen`
- An Apple Developer account **signed into Xcode**: Xcode → Settings →
  Accounts → **+** → Apple ID. Without this, signing fails with
  *"No Accounts: Add a new account in Accounts settings."*

The Xcode project is generated from [`project.yml`](project.yml) rather than
committed — no 20,000-line `pbxproj` to merge-conflict over, and the things
you'd personalise live in one readable place.

### 2. Set your bundle ID and team

In [`project.yml`](project.yml), under `settings.base`:

```yaml
settings:
  base:
    APP_BUNDLE_ID: com.adamodeven.tudget   # must be globally unique
    DEVELOPMENT_TEAM: "2VT8NJTJY6"         # your 10-char Apple Team ID
```

Your Team ID is at [developer.apple.com/account](https://developer.apple.com/account)
→ Membership details. The extensions' bundle IDs and the App Group are all
derived from `APP_BUNDLE_ID`, so it's the only place you set it.

### 3. Generate, then run

```bash
cd ios
xcodegen generate
open Tudget.xcodeproj
```

Pick the **Tudget** scheme and your device, and run. On the first device
build Xcode registers the App Group (`group.<your bundle id>`) automatically.

> If it complains about entitlements, open **Signing & Capabilities** on all
> three targets (Tudget, TudgetShare, TudgetWidgets) and confirm the same App
> Group is listed on each.

### 4. Tests

⌘U, or:

```bash
xcodebuild test -project Tudget.xcodeproj -scheme Tudget \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

---

## Using it

**Set up.** First launch walks through currency, cycle length, take-home pay
per cycle, and category limits, seeded from a modified 50/30/20 split. Change
any of it later in Settings.

**Type a purchase.** Tap *Add a purchase* — from the bar above the tab bar,
the Control Centre button, or a widget. One line does it:
`Trader Joe's $34 groceries`. What it understood is shown before you commit.

**From a screenshot.** Screenshot the bank alert → Share → Tudget. Vision
reads it on device, you tap a category, and it's in the ledger before the
share sheet finishes closing. The raw recognised text is one tap away, so a
bad parse is obvious rather than mysterious.

**Categorising later.** Anything logged without a category collects under
*Needs a category* on the dashboard. Tapping one gives a grid of categories,
and picking one shows the same "what's left" line the SMS version used to
text back: `Food: $387 of $400 left. Period total: $587 of $600 left.`

**Add the Control Centre button.** Swipe down from the top-right → **+** →
search *Tudget* → add **Add a Purchase**. It also works as a Lock Screen
control and in Shortcuts / Siri.

---

## How it's put together

```
ios/
  project.yml                    XcodeGen spec — bundle ID and team live here
  Tudget/
    TudgetApp.swift              @main, model container, router
    Core/                        pure logic, compiled into every target
      Currency.swift             symbols, codes, formatting
      CurrencyParser.swift       "€12,47" -> (12.47, EUR)
      PurchaseTextParser.swift   typed entry + OCR'd notification text
      CategoryMatcher.swift      "grub" -> Food, with typo tolerance
      BudgetPeriod.swift         fortnightly cycles anchored to a Monday
      BudgetCalculator.swift     spend / remaining / totals
      RunwayProjection.swift     burn rate -> the day you run out
      FXRateService.swift        live rates, cached, offline fallback
      VisionOCR.swift            screenshot -> text, on device
    Models/                      SwiftData: Transaction, BudgetCategory, Ledger
    Views/                       dashboard, pace, add, history, setup, settings
    Shared/                      App Group: store, settings, quick actions
    Intents/                     App Intents behind Control Centre & Siri
    Notifications/               budget alerts
  TudgetShare/                   share extension
  TudgetWidgets/                 widgets + Control Centre controls
  TudgetTests/                   62 tests over Core/
```

`Core/`, `Models/`, `Shared/`, and `Intents/` compile into the app, the share
extension, and the widgets, so parsing and budget maths can't drift between
"logged in the app" and "shared from the share sheet."

### One store, three processes

The app, the share extension, and the widgets all open the **same** SwiftData
store, in the App Group container. That's what lets a purchase shared from
the share sheet be in the ledger — and on the Home Screen widget — without
the app ever being launched.

Every mutation goes through `Ledger`, which saves and then reloads the widget
timelines, so no caller has to remember the refresh.

### Two decisions worth knowing about before you edit

**The data model is CloudKit-shaped, but sync is off.** Every property has a
default, relationships are optional, and nothing is `@Attribute(.unique)` —
the things CloudKit requires and that cost a migration to retrofit. Turning
iCloud sync on is two edits: uncomment the iCloud keys in
`Tudget/Supporting/Tudget.entitlements`, and change `cloudKitDatabase: .none`
to `.automatic` in `Shared/LedgerStore.swift`.

**The category colours are validated, not chosen by eye.** They're the
Okabe-Ito colourblind-safe palette, re-stepped separately for light and dark
(an automatic flip fails the dark lightness band). Both sets pass a full
check — lightness band, chroma floor, normal-vision separation, CVD
separation, contrast. Two rules keep that true:

- Worst-pair CVD separation sits in the 6–8 band, which is only legal
  alongside a second, non-colour channel. Every surface showing a category
  shows its **emoji and name** too. Don't build one that doesn't.
- `neutral` is deliberately grey and deliberately *not* a sixth hue. Six
  saturated hues can't all clear the normal-vision floor inside the narrow
  dark-mode band; five plus a neutral "Other" can.

See the comment at the top of `Models/CategoryTint.swift`.

---

## A note on automatic capture

The long-term goal was intercepting bank notifications automatically. Where
that stands:

**iOS does not allow it.** There's no public API for one app to read another
app's notifications — no equivalent to Android's
`NotificationListenerService` — and Shortcuts has no "notification received"
trigger. This isn't a limitation of this app; nothing on the App Store can do
it.

So on iPhone the realistic paths to "I didn't type this in" are the share
extension (built) and, eventually, an Android phone running a notification
listener that posts to [`../server`](../server) for the app to pull. That
Android app doesn't exist yet.

---

## Ship it to TestFlight

Only needed if you want it installed without a cable, or on someone else's
phone. For your own device, running from Xcode is enough.

1. **App Store Connect** → Apps → **+** → New App. Bundle ID is your
   `APP_BUNDLE_ID` (it appears in the dropdown once Xcode has registered it —
   building to a device once is the easiest way).
2. In Xcode set the destination to **Any iOS Device (arm64)**, then
   **Product → Archive**.
3. Organizer → **Distribute App** → **TestFlight & App Store** → Upload.
4. App Store Connect → your app → **TestFlight** → add yourself under
   **Internal Testing**. Internal builds skip Beta App Review, so it's usually
   minutes.

To bump the build number between uploads, edit `CURRENT_PROJECT_VERSION` in
`project.yml` and re-run `xcodegen generate`. `ITSAppUsesNonExemptEncryption`
is already `false`, so you won't be asked about export compliance each time.
