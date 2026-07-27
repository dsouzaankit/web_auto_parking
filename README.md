# ParkMobile / SpotHero Parking (iOS)

SwiftUI wrapper that opens provider checkout in a `WKWebView`, starting at the **next 15-minute mark**.

## Prefill contact (edit by hand)

`BookingConfig.json` is **gitignored** (personal data). Copy the template once, then edit locally:

```bash
cp ios/ParkMobileParking/Resources/BookingConfig.example.json \
   ios/ParkMobileParking/Resources/BookingConfig.json
```

Template: [`BookingConfig.example.json`](ios/ParkMobileParking/Resources/BookingConfig.example.json). Rebuild after changes. Empty / `...` values are skipped. The WebView:

- Prefills **contact** (email / phone / address) and **vehicle** (make & model, plate, country, state — including `<select>` matches)
- Prefers **guest checkout** (clicks Continue as Guest when shown; does not drive Log In)
- Selects **Apple Pay** when that option is on the page (requires iPhone Wallet / Safari-capable WebView; desktop often has no Apple Pay radio)

`sessionDurationHours` may be `3` or `4` (ParkMobile locked window). The Garages tab also has a **3 hours / 4 hours** control that overrides this at runtime.

## Providers

| Provider | Example | URL shape |
|----------|---------|-----------|
| **ParkMobile** | [1525 Harbor Garage](https://app.parkmobile.io/reservation/62713) | `/reservation/{id}?startDate=…&endDate=…` (**3h or 4h** locked) |
| **ParkMobile** | [(SP+) The Bisby Garage](https://app.parkmobile.io/reservation/59277) | same |
| **SpotHero** | [29245 Mall Dr. E](https://spothero.com/purchase/hourly?facility=131895) | `/purchase/hourly?facility={id}&starts=…` (**no `ends`** — free extra time kept) |

Presets above are saved by default (existing installs pick up missing ones on next launch).

## Session defaults

| Setting | ParkMobile | SpotHero |
|---------|------------|----------|
| **Start** | Next **15-minute** mark | Same |
| **Duration** | Global **3h or 4h** (config + in-app toggle) | Not forced — checkout may add **free extra time** |
| **End** | Start + duration | Omitted so the rate package can extend |

## Tabs

| Tab | Behavior |
|-----|----------|
| **Garages** | Saved facilities → provider checkout |
| **ParkMobile** | Find Parking search |
| **SpotHero** | SpotHero home / search |
| **Zone** | ParkMobile meter / zone start |

## Build & install (no Mac)

See [ios/BUILD-WITHOUT-MAC.md](ios/BUILD-WITHOUT-MAC.md) — same pattern as `ios_3d_loop_segments`:

1. GitHub **Actions → ios-build → Run workflow**
2. Download **`ParkMobileParking-ipa`**
3. Install via **AltStore → My Apps → +**

```bash
brew install xcodegen
cd ios && xcodegen generate && open ParkMobileParking.xcodeproj
```

## Limits

- Booking/payment stays on the provider site.
- Thin WebView wrapper — fine for personal sideload.
