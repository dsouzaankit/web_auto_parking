# ParkMobile Zone — known baseline (update when live diverges)

Snapshot of what automation expects after the 2026 Zone SPA move. Treat as **last known good**, not eternal truth — live logs win.

## Expected v2 path

```
/search
  → (optional address) /search/{place}
  → /v2/parking/zone-details?areaNo={internal}
  → /v2/parking/guest-registration
  → /v2/parking/add-vehicle
  → /v2/parking/duration
  → /v2/parking/confirm
  → Apple Pay (user)
  → /v2/parking/session/guest/{uuid}
```

Legacy fallback (still keep): `/zone/start|auth|vehicle|duration|payment|review` and `/sessions/{uuid}`.

## Stable hooks (last known)

| Step | Prefer |
|------|--------|
| Guest email | `guest-registration-email-input` |
| Guest terms | `terms-checkbox` / `terms-checkbox-control-input` |
| Guest continue | `guest-registration-continue-button` |
| Vehicle plate | `vehicle-form-license-plate-input` |
| Duration hours | `duration-flexible-hours-option-{0..N}` |
| Duration minutes | `duration-flexible-minutes-option-{20,40,…}` |
| Duration continue | `duration-continue-button` |
| Error UI | `error-overlay-title`, **Try again**, `error-overlay-close-button` |
| Confirm pay CTA | `apple-pay-button` — **select method only; never auto-tap** |

## APIs that matter

| Purpose | Pattern |
|---------|---------|
| Map search (do **not** write Attempted) | `/api/zones/search` |
| Tariff / duration caps | zone tariff / `timebasedOptions` |
| Pay (Receipts) | `POST /v2/parking/api/order/purchase` |
| Session detail (Receipts) | `GET /v2/parking/api/parking/{uuid}` — fields like `data.id`, `signageAreaCode`, `priceInclVat`, plate |
| Legacy pay | `POST …/ondemand-guest-purchase` + `/sessions/{uuid}` |

JSON may nest under `data`. Prefer uuid-looking string ids for receipt keys (not numeric parking row `id` unless product asks).

## Race: guest “An error occurred”

Cause: **Park here** on zone-details before pricing/session ready.  
Mitigation: wait first-hour pricing or ~2.8s before **auto** Park here (address path); geo path pauses for manual **Park here** (`awaitManualZoneConfirm`); then overlay dismiss / **Try again**; recover via cached `areaNo` if stuck on `/v2/parking` or `zones/map`.  
LAN: `v2 zone-details waiting settle`, `awaitManualZoneConfirm`, `v2 Try again tapped`, `v2 error overlay closed`, `v2 recover zone-details`.

## Geo vs address on zone-details

| Source | zone-details **Park here** |
|--------|----------------------------|
| GPS nearest (`/search` + geo, ≤~2.5 km) | **Manual** — `awaitManualZoneConfirm` |
| Address slug (`/search/{place}`) | **Auto** after settle |
| Attempted / deep link | **Auto** (flag unset) |

## Z. History split

- **Attempted**: unfinished checkouts from zone-details / zone start (internal code). Ignore paid session + purchase URLs.
- **Receipts**: paid uuid links (legacy `/sessions/` or v2 guest session). Copy link / Paste link backup.

## LAN log greps that usually pay off

```
v2ParkingDiag|Prefill JS|awaitAddressSearch|pickZone|Park here
v2 zone-details waiting settle|v2 Try again|v2 error overlay|v2 recover
v2 duration picked|v2 Add vehicle|v2 guest|apple-pay|awaitCheckout
Attempted zone cached|ParkingSession|purchase|/v2/parking/session
```

## Git note

`ai/` capture dumps are often **gitignored**. Fix code + README in git; do not rely on committing `live_*.txt` unless the user forces it.
