# Web Auto Parking (iOS)

SwiftUI wrapper that opens provider checkout in a `WKWebView`, defaulting to the **last 15-minute mark** start (toggle ASAP / −15m / −30m), with automated guest/contact/vehicle steps on ParkMobile and SpotHero, plus ParkChirp Harbor (sign-in, evening window walk).

## Prefill config (edit by hand)

`BookingConfig.json` is **gitignored** (personal data). Copy the template once, then edit locally:

```bash
cp ios/WebAutoParking/Resources/BookingConfig.example.json \
   ios/WebAutoParking/Resources/BookingConfig.json
```

Template: [`BookingConfig.example.json`](ios/WebAutoParking/Resources/BookingConfig.example.json). Empty / `...` values are skipped.

Use **ISO-style codes** for selects when possible (`country`: `US`, `state`: `NJ`). Full names like `United States` / `New Jersey` are normalized on load.

### What automation does

On checkout / login-to-checkout pages (not Find search), the WebView will:

| Step | ParkMobile | SpotHero | ParkChirp |
|------|------------|----------|-----------|
| Start booking | Open checkout with session window (Z-stamped times; skips Reserve race) | Facility purchase URL opens checkout | Hourly checkout (**5:30…11:00→11:30**, today through **current+2**) |
| Auth | **Continue as a Guest** | Guest checkout by default | **Wait for sign-in**; if email+password are filled (e.g. Password AutoFill), tap **Login Submit** once — never Sign in with Apple / SSO |
| Contact | Fill email / phone → **Save & Continue** | Fill email / phone → **Continue** | Account fields already on file after login |
| Vehicle | Fill `#vrn` plate, country, state → **Save & Continue** | Tap **Add** → select **Make and Model** → plate + state → **Confirm** | Select matching plate radio if configured |
| Payment | Tap **Continue with Apple Pay** (Payment Details only — not Sign in with Apple); check **I acknowledge…** (does not complete purchase) | Leaves payment alone | Leaves **Checkout** to the user (does not tap it) |

- Prefill runs automatically on reservation / checkout / login-with-checkout / ParkChirp facility URLs; toolbar **wand** also runs it manually.
- Visible captcha challenges pause fill (badge-only reCAPTCHA is ignored).
- SpotHero’s vehicle popup has **State or Province** only (no Country field).
- **ParkMobile time quirk:** their checkout builder takes UTC clock hours then appends the local offset, so a real `09:45-04:00` becomes `13:45-04:00` (start jumps to the old end / 1:45 PM). We open `/checkout/reservation/…` directly with local wall times stamped as `Z` (e.g. `09:45:00Z`) so their UTC getters keep the ASAP hour. Do not switch back to naive/`-04:00` `startDate`+Reserve without retesting.
- **Lincoln Harbor evening package:** [1525 Harbor Garage](https://app.parkmobile.io/reservation/62713) (`62713`) often rewrites evening ASAP/−15m/−30m 3–6h windows into a fixed **~5:30 PM → 12:30 AM (7h)** rate package. Z-stamped checkout still works (no UTC hour jump); Bisby keeps the requested window. This is ParkMobile’s rate packaging for that facility, not an app start-mode bug.
- **ParkChirp time quirk:** deep-link `startTime`/`endTime` are unix seconds. If you pass a real Eastern epoch, their GUI shows **UTC clock hours as local** (e.g. 5:30 PM EDT → **9:30 PM**). Same class of bug as ParkMobile. We stamp **local wall clock as if UTC** (`SessionWindow.unixParkChirpWallSeconds`) so 5:30 PM stays 5:30 PM. Do not switch to real EDT timestamps without retesting.
- **ParkChirp Harbor evening walk:** [1525 Harbor Blvd](https://parkchirp.com/facilities/1525-harbor-blvd/) (`1525-harbor-blvd`, facility `96657`) ignores Session ASAP/−15m/−30m and 3–6h duration. Deep link opens **today 5:30 PM → 11:30 PM**. After sign-in + plate, prefill walks until the SPA **keeps a window as-is** or the day hits **current + 2** (whichever is earlier): for each day, try start **5:30 / 6:00 / … / 11:00 PM** with end **11:30 PM** (`setTimes` / `parkChirpTimesPending`, ~2s settle). Skips dates/times missing from the picker (past start, **lot full / sold out**, etc.). Login: `autofillHint` focuses email for saved **parkchirp.com** credentials. Stops at **Checkout**; payment HTTP **500** on saved/real card (PC and in-app) — provider-side; treat purchase as manual.
- **ParkChirp Harbor SPA rewrite:** within ~1s they may rewrite deep links when start is past/unavailable or today is sold out. Invalid/past starts often become overnight (**next day 12:00 AM → 11:30 PM**, `expectedPrice=3000` / **`$30`**). A kept evening window ending 11:30 is typically **`$5`**. Do not thrash `replaceState` on unavailable today — advance start slots, then later dates through current+2.

`sessionDurationHours` may be `3`, `4`, `5`, or `6` (fixed-duration locked window; **not** used by ParkChirp Harbor). The Garages tab also has a **3h / 4h / 5h / 6h** control that overrides this at runtime for ParkMobile fixed lots.

## LAN logs (Wi‑Fi)

1. Phone and PC on the same Wi‑Fi; allow **Local Network** when prompted.
2. Open **`http://<phone-ip>:8765/`** (prefer IP on Windows) or **`/logs.txt`**.
3. Toggle under **Garages → LAN logs**. Bonjour name: `webautoparking._http._tcp`.
4. Log file is **cleared on each app launch** (cold start), then starts with `App launch v… build …`.

Useful log lines: `Prefill inject`, `Prefill JS {"status":"advanced|filled|waiting",...}`, `action":"reserve|guest|awaitSignIn|autofillHint|loginSubmit|setTimes|awaitCheckout|saveContinue|vehicleAdd|vehicleConfirm|applePay|acknowledge"`.

## Providers

| Provider | Example | URL shape |
|----------|---------|-----------|
| **Fixed duration** | [1525 Harbor Garage](https://app.parkmobile.io/reservation/62713) | `/checkout/reservation/{id}?start_at=…Z&stop_at=…Z` (**3–6h** locked) |
| **Fixed duration** | [(SP+) The Bisby Garage](https://app.parkmobile.io/reservation/59277) | same (vehicle plate required) |
| **Flexible** | [29245 Mall Dr. E](https://spothero.com/purchase/hourly?facility=131895) | `/purchase/hourly?facility={id}&starts=…` (**no `ends`** — free extra time kept) |
| **ParkChirp** | [1525 Harbor Blvd](https://parkchirp.com/facilities/1525-harbor-blvd/?checkout=true&type=hourly) | `/facilities/{slug}/?checkout=true&type=hourly&startTime=…&endTime=…` (unix **wall-as-UTC**; **5:30…11:00→11:30 through current+2** — list tag **Fixed duration**; **sign-in required**) |

Presets above are saved by default (existing installs pick up missing ones on next launch; **ParkChirp Harbor is listed last**).

## Session defaults

| Setting | Fixed duration (ParkMobile) | Flexible (SpotHero) | ParkChirp Harbor |
|---------|----------------------------|---------------------|------------------|
| **Start** | **Last 15m** (or ASAP / last 30m) | Same | **5:30…11:00 PM** (per day through current+2; walk until accepted) |
| **Duration** | Global **3–6h** (config + in-app toggle) | Not forced — may add **free extra time** | End locked at 11:30 PM |
| **End** | Start + duration | Omitted so the rate package can extend | **11:30 PM** (same candidate day) |

## Tabs

| Tab | Behavior |
|-----|----------|
| **Garages** | Saved facilities → provider checkout (main automation path) |
| **Find** | ParkMobile / SpotHero search (segmented); prefill skipped until checkout |
| **Zone** | Meter / zone start |

## Build & install (no Mac)

See [ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md). Short path:

1. Push to `master` (or **Actions → ios-build → Run workflow** — IPA only builds on `workflow_dispatch`)
2. Download **`WebAutoParking-ipa`**
3. Run **`.\deploy.ps1`** — injects your local `BookingConfig.json` into the IPA and copies a timestamped file to iCloud Drive Downloads
4. Install via **AltStore → My Apps → +**

CI ships the example config; personal installs need step 3 (or the IPA will prefill placeholders).

```bash
brew install xcodegen
cd ios && xcodegen generate && open WebAutoParking.xcodeproj
```

## Limits

- Booking/payment stays on the provider site; automation does not complete payment.
- Thin WebView wrapper — fine for personal sideload.
- Make/model on SpotHero must match an autosuggest option (e.g. `Chevrolet Impala`).
