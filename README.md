# Web Auto Parking (iOS)

SwiftUI wrapper that opens provider checkout in a `WKWebView`, defaulting to the **last 15-minute mark** start (toggle ASAP / −15m / −30m), with automated guest/contact/vehicle steps on ParkMobile and SpotHero.

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

| Step | ParkMobile | SpotHero |
|------|------------|----------|
| Start booking | Open checkout with ASAP window (Z-stamped times; skips Reserve race) | (facility purchase URL opens checkout) |
| Guest | **Continue as a Guest** | Guest checkout by default |
| Contact | Fill email / phone → **Save & Continue** | Fill email / phone → **Continue** |
| Vehicle | Fill `#vrn` plate, country, state → **Save & Continue** | Tap **Add** → select **Make and Model** from dropdown → plate + state → **Confirm** |
| Payment | Tap **Continue with Apple Pay** (Payment Details only — not Sign in with Apple); check **I acknowledge…** (does not complete purchase) | Leaves payment alone |

- Prefill runs automatically on reservation / checkout / login-with-checkout URLs; toolbar **wand** also runs it manually.
- Visible captcha challenges pause fill (badge-only reCAPTCHA is ignored).
- SpotHero’s vehicle popup has **State or Province** only (no Country field).
- **ParkMobile time quirk:** their checkout builder takes UTC clock hours then appends the local offset, so a real `09:45-04:00` becomes `13:45-04:00` (start jumps to the old end / 1:45 PM). We open `/checkout/reservation/…` directly with local wall times stamped as `Z` (e.g. `09:45:00Z`) so their UTC getters keep the ASAP hour. Do not switch back to naive/`-04:00` `startDate`+Reserve without retesting.
- **Lincoln Harbor evening package:** [1525 Harbor Garage](https://app.parkmobile.io/reservation/62713) (`62713`) often rewrites evening ASAP/−15m/−30m 3–6h windows into a fixed **~5:30 PM → 12:30 AM (7h)** rate package. Z-stamped checkout still works (no UTC hour jump); Bisby keeps the requested window. This is ParkMobile’s rate packaging for that facility, not an app start-mode bug.
- **ParkChirp Harbor:** same garage via [parkchirp.com/facilities/1525-harbor-blvd](https://parkchirp.com/facilities/1525-harbor-blvd/). Deep links use wall-clock stamped as UTC unix `startTime`/`endTime` (real EDT epochs show +4h). Window is **locked to 5:30 PM → 11:30 PM** (Session ASAP/−15m/−30m + duration ignored). Automation **waits for account sign-in** and does not tap Checkout (saved-card charges have returned processor 500s in testing).

`sessionDurationHours` may be `3`, `4`, `5`, or `6` (fixed-duration locked window). The Garages tab also has a **3h / 4h / 5h / 6h** control that overrides this at runtime.

## LAN logs (Wi‑Fi)

1. Phone and PC on the same Wi‑Fi; allow **Local Network** when prompted.
2. Open **`http://<phone-ip>:8765/`** (prefer IP on Windows) or **`/logs.txt`**.
3. Toggle under **Garages → LAN logs**. Bonjour name: `webautoparking._http._tcp`.

Useful log lines: `Prefill inject`, `Prefill JS {"status":"advanced|filled|waiting",...}`, `action":"reserve|guest|saveContinue|vehicleAdd|vehicleConfirm|applePay|acknowledge"`.

## Providers

| Provider | Example | URL shape |
|----------|---------|-----------|
| **Fixed duration** | [1525 Harbor Garage](https://app.parkmobile.io/reservation/62713) | `/checkout/reservation/{id}?start_at=…Z&stop_at=…Z` (**3–6h** locked) |
| **Fixed duration** | [(SP+) The Bisby Garage](https://app.parkmobile.io/reservation/59277) | same (vehicle plate required) |
| **Flexible** | [29245 Mall Dr. E](https://spothero.com/purchase/hourly?facility=131895) | `/purchase/hourly?facility={id}&starts=…` (**no `ends`** — free extra time kept) |
| **ParkChirp** | [1525 Harbor Blvd](https://parkchirp.com/facilities/1525-harbor-blvd/?checkout=true&type=hourly) | `/facilities/{slug}/?checkout=true&type=hourly&startTime=…&endTime=…` (unix wall-as-UTC; **locked 5:30–11:30 PM**; **sign-in required**) |

Presets above are saved by default (existing installs pick up missing ones on next launch).

## Session defaults

| Setting | Fixed duration | Flexible |
|---------|----------------|----------|
| **Start** | **Last 15m** mark by default (or ASAP / last 30m) | Same |
| **Duration** | Global **3–6h** (config + in-app toggle) | Not forced — checkout may add **free extra time** |
| **End** | Start + duration | Omitted so the rate package can extend |

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
