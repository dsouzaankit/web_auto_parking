# ParkMobile Zone XHR / flow notes

Drop HAR exports or request dumps from Web Inspector here (`*.har`, `*.json`).

## Current entry URL

Zone tab starts at **`https://app.parkmobile.io/zone/start`**. ParkMobile prefills nearest **Zone #** via geolocation. App loops **Continue** (pause on submit errors for manual re-submit) until URL is **`/zone/auth?checkoutState=…`**, then guest/checkout prep runs.

## Learned from live `/search` (2026-08-03)

### Mode switch

- Map toggle: **Reserve Parking** vs **Search Zones** (`role=radio`, aria `search zones`).
- Zone list only appears after **Search Zones** is selected.
- Geolocation control: button **Get user location**.

### Network

- Zone pins/list: `GET https://app.parkmobile.io/api/zones/search?parkingType=1&upper={lat},{lng}&lower={lat},{lng}`  
  Often also includes `center=`, `startDate=`, `endDate=`, `maxResults=`, `includeServices=true`.
- Transient companion: `GET …/api/zones/search/transient?…`
- Reserve-parking map uses `parkingType=2` (venues / priced pins) — not the zone workflow.

### DOM / navigation

- List rows expose public **Zone # NNNN** plus:
  - Details → `/zone/{internalZoneCode}`
  - **Park Here** → `/zone/start?internalZoneCode={internalZoneCode}`
- Example: Zone # `1972` → `internalZoneCode=1081972`
- `/zone/start` shows **Zone #** text field + **Confirm Zone**, then duration / checkout steps.

### Automation choices in-app

1. Select Search Zones → tap Get user location.
2. Prefer nearest from cached `/api/zones/search` (haversine vs native lat/lng); else first listed Park Here (nearest-first after geo).
3. Native alert confirms public `zone-id` before activating Park Here.
4. Duration: greatest hour/minute options ≤ **100 minutes** (1h 40m).
5. Reuse existing guest → contact → vehicle → Apple Pay prep (no purchase).
6. `/zone/vehicle` (Add Vehicle): force plate + country + state from `BookingConfig` (overwrite defaults), then Continue.

## What to export for refinement

When you run the real NJ flow, save from `localhost:9222` / Web Inspector:

1. `/api/zones/search?parkingType=1…` response JSON (field names for lat/lng/zone codes)
2. Requests after **Confirm Zone** (duration options / rates)
3. Guest / payment XHR if selectors differ from garage reservation checkout
