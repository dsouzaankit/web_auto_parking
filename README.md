# Web Auto Parking (iOS)

SwiftUI wrapper that opens provider checkout in a `WKWebView`, defaulting to the **last 15-minute mark** start (toggle ASAP / −15m / −30m), with automated guest/contact/vehicle steps on ParkMobile and SpotHero, plus ParkChirp Harbor (sign-in, evening window walk), and a **Zone** tab for ParkMobile `/search` (nearest zone via SPA geo → duration ≤ 2h → Apple Pay prep).

## Prefill config (edit by hand)

`BookingConfig.json` is **gitignored** (personal data). Copy the template once, then edit locally:

```bash
cp ios/WebAutoParking/Resources/BookingConfig.example.json \
   ios/WebAutoParking/Resources/BookingConfig.json
```

Template: [`BookingConfig.example.json`](ios/WebAutoParking/Resources/BookingConfig.example.json). Top-level **`email`** / **`phone`** are prefilled on zone + garage checkout (overwrites guest temp emails). Empty / `...` values are skipped.

Use **ISO-style codes** for selects when possible (`country`: `US`, `state`: `NJ`). Full names like `United States` / `New Jersey` are normalized on load.

### What automation does

On checkout / login-to-checkout pages, the WebView will:

| Step | ParkMobile | SpotHero | ParkChirp |
|------|------------|----------|-----------|
| Start booking | Open checkout with session window (Z-stamped times; skips Reserve race) | Facility purchase URL opens checkout | Hourly checkout (**5:30…11:00→11:30**, today through **current+2**) |
| Auth | **Continue as a Guest** | Guest checkout by default | Cognito **Log In**: sets `autocomplete` only — **does not** JS-focus or JS-fill (that blocks/dismisses Keychain in `WKWebView`). Alert: tap **Email Address** → **Passwords** / key icon. Then auto-**Submit** when password is filled (≥8 / autofill). Never ABM SSO / Create Account |
| Contact | Fill email / phone → **Save & Continue** | Fill email / phone → **Continue** | Account fields already on file after login |
| Vehicle | Fill `#vrn` plate, country, state → **Save & Continue** | Tap **Add** → select **Make and Model** → plate + state → **Confirm** | Select matching plate radio if configured |
| Payment | Tap **Continue with Apple Pay** (Payment Details only — not Sign in with Apple); check **I acknowledge…** (does not complete purchase) | Leaves payment alone | Leaves **Checkout** to the user (does not tap it) |

- **Button labels are brittle.** The table above is the providers’ current copy (e.g. ParkMobile garage/vehicle **Save & Continue** vs bare **Continue**). Prefill prefers stable hooks when present (`data-pmtest-id`, `data-testid`, fields like `#vrn`) and falls back to visible label text. A provider rename or layout change can stall a step even though the form looks filled — check LAN logs (`vehicleDiag`, `Save & Continue tapped` / `forced`, `vehicle Continue tapped btn=…`) and re-anchor selectors in `BookingFormPrefill.swift`.
- Prefill runs automatically on reservation / checkout / login-with-checkout / ParkChirp facility URLs; toolbar **wand** also runs it manually.
- Visible captcha challenges pause fill (badge-only reCAPTCHA is ignored).
- SpotHero’s vehicle popup has **State or Province** only (no Country field).
- **ParkMobile time quirk:** their checkout builder takes UTC clock hours then appends the local offset, so a real `09:45-04:00` becomes `13:45-04:00` (start jumps to the old end / 1:45 PM). We open `/checkout/reservation/…` directly with local wall times stamped as `Z` (e.g. `09:45:00Z`) so their UTC getters keep the ASAP hour. Do not switch back to naive/`-04:00` `startDate`+Reserve without retesting.
- **Harbor 6h open override:** tapping [1525 Harbor Garage](https://app.parkmobile.io/reservation/62713) (`62713`) sets Fixed duration to **6h** for that open. Tap a **1h–6h** segment first if you want a different length for the next open; another Harbor tap without touching the picker resets to 6h again. Bisby and other lots keep the picker as-is.
- **1525 Harbor evening package:** [1525 Harbor Garage](https://app.parkmobile.io/reservation/62713) (`62713`) often rewrites evening ASAP/−15m/−30m 1–6h windows into a fixed **~5:30 PM → 12:30 AM (7h)** rate package. Z-stamped checkout still works (no UTC hour jump); Bisby keeps the requested window. This is ParkMobile’s rate packaging for that facility, not an app start-mode bug.
- **ParkChirp time quirk:** deep-link `startTime`/`endTime` are unix seconds. If you pass a real Eastern epoch, their GUI shows **UTC clock hours as local** (e.g. 5:30 PM EDT → **9:30 PM**). Same class of bug as ParkMobile. We stamp **local wall clock as if UTC** (`SessionWindow.unixParkChirpWallSeconds`) so 5:30 PM stays 5:30 PM. Do not switch to real EDT timestamps without retesting.
- **ParkChirp Harbor evening walk:** [1525 Harbor Blvd](https://parkchirp.com/facilities/1525-harbor-blvd/) (`1525-harbor-blvd`, facility `96657`) ignores Session ASAP/−15m/−30m and 1–6h duration. Deep link opens the **first still-viable** evening slot (start **5:30…11:00 PM** → end **11:30 PM**, today through **current+2**) — not a past 5:30 (that makes their SPA stick on overnight **`$30`**). After sign-in + plate, prefill walks remaining candidates until the SPA **keeps a window as-is** or the list is exhausted (`setTimes` / `parkChirpTimesPending`, ~2s settle). Skips dates/times missing from the picker (**lot full / sold out**, etc.). Login: `WKWebView` **cannot fetch Keychain**. Prefill only sets `autocomplete=username/current-password` and shows a one-time alert — **you** tap Email → Passwords/key. No JS `focus()` / email inject (those dismiss the Passwords bar). After credentials are in the fields, taps Cognito **Submit** (`loginSubmit` / `parkChirpLoginDiag`). Password is never stored in the app. Stops at **Checkout**; payment HTTP **500** on saved/real card (PC and in-app) — provider-side; treat purchase as manual.
- **ParkChirp Harbor SPA rewrite:** within ~1s they may rewrite deep links when start is past/unavailable or today is sold out. Invalid/past starts often become overnight (**next day 12:00 AM → 11:30 PM**, `expectedPrice=3000` / **`$30`**). A kept evening window ending 11:30 is typically **`$5`**. Do not thrash `replaceState` on unavailable today — advance start slots, then later dates through current+2.

`sessionDurationHours` may be `1`–`6` (fixed-duration locked window; **not** used by ParkChirp Harbor). The Garages tab has **3h / 4h / 5h / 6h** plus **1h / 2h** below that overrides this at runtime for ParkMobile fixed lots.

## LAN logs (Wi‑Fi)

1. Phone and PC on the same Wi‑Fi; allow **Local Network** when prompted.
2. Open **`http://<phone-ip>:8765/`** (prefer IP on Windows), **`/logs.txt`**, or **`/xhr.txt`**.
3. Toggle under **Garages → LAN logs**. Bonjour name: `webautoparking._http._tcp`.
4. Log file is **cleared on each app launch** (cold start), then starts with `App launch v… build …`.

Useful log lines: `Prefill inject`, `Prefill JS {"status":"advanced|filled|waiting",...}`, `action":"awaitZonePrefill|awaitManualZoneSubmit|awaitZoneAuth|zoneContinue|setDuration|searchZonesMode|geo|pickZone|reserve|guest|awaitSignIn|autofillHint|loginSubmit|setTimes|awaitCheckout|saveContinue|vehicleAdd|vehicleConfirm|applePay|acknowledge"` (ParkChirp Keychain: bridge `parkChirpKeychain`), plus bridge hints like `vehicleDiag`, `Save & Continue tapped` / `forced`, `vehicle Continue tapped btn=…`.

**XHR capture (preferred on Windows):** the app hooks `fetch` / `XMLHttpRequest` in the WebView and writes request/response bodies to **`/xhr.txt`** (summaries also appear as `XHR …` lines in `/logs.txt`). Use this instead of the Web Inspector Network panel.

## WebView inspector (Windows, USB)

Safari Web Inspector via [`ios-safari-remote-debug-kit`](https://github.com/HimbeersaftLP/ios-safari-remote-debug-kit) is useful for DOM/console, but on Windows **`ios-webkit-debug-proxy` usually does not expose the Network domain** (`Network was not found` / no XHR). Prefer **`/xhr.txt`** above for API learning.

1. App sets `webView.isInspectable = true` (iOS 16.4+).
2. Phone: **Settings → Safari → Advanced → Web Inspector** on; USB + trust in **Apple Devices**.
3. From `P:\all_scripts\iOS apps\env_setup`: run `.\start-ios-webview-debug.ps1` (first-time: `.\setup-ios-webview-debug.ps1`).
4. Open a page in the app, pick it at `http://localhost:9222/`, then `http://localhost:8080/Main.html?ws=localhost:9222/devtools/page/N`.
5. If the inspector shows **Internal Error** / `Program` TypeError, close extra inspector tabs (only one client per page), regenerate protocol for your iOS major version, or skip Network and use `/xhr.txt`.

## Providers

| Provider | Example | URL shape |
|----------|---------|-----------|
| **Fixed duration** | [(SP+) The Bisby Garage](https://app.parkmobile.io/reservation/59277) | `/checkout/reservation/{id}?start_at=…Z&stop_at=…Z` (**1–6h** locked; vehicle plate required) |
| **Fixed duration** | [1525 Harbor Garage](https://app.parkmobile.io/reservation/62713) | same (**opens at 6h** unless picker was just changed) |
| **Flexible** | [29245 Mall Dr. E](https://spothero.com/purchase/hourly?facility=131895) | `/purchase/hourly?facility={id}&starts=…` (**no `ends`** — free extra time kept) |
| **ParkChirp** | [1525 Harbor Blvd](https://parkchirp.com/facilities/1525-harbor-blvd/?checkout=true&type=hourly) | `/facilities/{slug}/?checkout=true&type=hourly&startTime=…&endTime=…` (unix **wall-as-UTC**; **5:30…11:00→11:30 through current+2** — list tag **Fixed duration**; **sign-in required**) |

Presets above are saved by default in that order (existing installs pick up missing ones on next launch; **ParkChirp Harbor is listed last**).

## Session defaults

| Setting | Fixed duration (ParkMobile) | Flexible (SpotHero) | ParkChirp Harbor |
|---------|----------------------------|---------------------|------------------|
| **Start** | **Last 15m** (or ASAP / last 30m) | Same | **5:30…11:00 PM** (per day through current+2; walk until accepted) |
| **Duration** | Global **1–6h** (config + in-app 3–6h / 1–2h toggles); 1525 Harbor **force 6h on open** unless picker tapped first | Not forced — may add **free extra time** | End locked at 11:30 PM |
| **End** | Start + duration | Omitted so the rate package can extend | **11:30 PM** (same candidate day) |

## Tabs

| Tab | Behavior |
|-----|----------|
| **Garages** | Saved facilities → provider checkout (garage automation path) |
| **Zone** | Opens [`app.parkmobile.io/search`](https://app.parkmobile.io/search). **Search Zones** → **Get user location** → nearest **Park Here** → you tap **Confirm Zone** on the zone-id page (Zone # gets `inputmode=numeric` so the number pad opens first; ABC/globe still switches to full keyboard — no `pattern=[0-9]*` lock) → automation resumes (duration ≤ **2h** → guest → contact → vehicle → Apple Pay prep). |

### Zone flow notes

- Allow **Location** when prompted so ParkMobile can prefill the nearest zone.
- Loops **Continue** / **Confirm Zone** until `https://app.parkmobile.io/zone/auth?checkoutState=…`.
- On submit errors, waits for **manual re-submit**, then resumes the Continue loop.
- Duration (greedy, cap **2h**): pick the largest `#hours` with `h×60 ≤ 120` (values may be minute-encoded, e.g. `value="60"` = **1 Hour**), set it, then pick the largest live `#minutes` with total ≤ 120. Don’t score minutes before the hour is fixed — that list can refresh (20m steps plus an odd leftover for the zone max).
- If hour/minute selectors are missing, keeps tapping **Continue**.
- Capture notes / expected APIs: [`ai/parkmobile_zone_xhr/README.md`](ai/parkmobile_zone_xhr/README.md).

## Build & install (no Mac)

See [ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md). Short path:

1. Push to `master` (or **Actions → ios-build → Run workflow** — IPA only builds on `workflow_dispatch`)
2. Download **`WebAutoParking-ipa`**
3. Run **`.\deploy.ps1`** — injects `BookingConfig.json`, strips broken `_CodeSignature`, copies timestamped `WebAutoParking-b{build}-{timestamp}.ipa` to iCloud Downloads (removes older copies)
4. Install via **AltStore → My Apps → +** (force-quit/reopen AltStore if **incorrect/invalid format**; else **AltServer Sideload**)

CI ships the example config; personal installs need step 3 (or the IPA will prefill placeholders).

```bash
brew install xcodegen
cd ios && xcodegen generate && open WebAutoParking.xcodeproj
```

## Limits

- Booking/payment stays on the provider site; automation does not complete payment.
- Thin WebView wrapper — fine for personal sideload.
- Make/model on SpotHero must match an autosuggest option (e.g. `Chevrolet Impala`).
