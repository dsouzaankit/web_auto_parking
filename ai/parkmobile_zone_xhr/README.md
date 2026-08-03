# ParkMobile Zone XHR / flow notes

Drop HAR exports or request dumps from Web Inspector here (`*.har`, `*.json`).

## Current entry URL

Zone tab starts at **`https://app.parkmobile.io/search`**.

Automation:

1. Switch to **Search Zones**
2. Tap **Get user location** (native Core Location stubbed into `navigator.geolocation`)
3. Cache SPA `GET /api/zones/search?parkingType=1&upper=…&lower=…` (XHR — do **not** call this ourselves)
4. Pick nearest zone (haversine vs native lat/lng, else first Park Here)
5. **Park Here** → `/zone/start?internalZoneCode=…`
6. Duration ≤ 1h 40m → Continue through guest/contact/vehicle → Apple Pay prep

## Learned from live XHR (build 41, `/zone/start` attempt)

### Broken path (our automation)

```
GET /api/zones/search?parkingType=1&upper=…%2C…&lower=…&center=…&maxResults=40&includeServices=true
→ HTTP 400 body {"message":"Request failed with status code 422"}
```

Direct `fetch` from the prefill script fails. Do not use this for nearest-zone.

### Working SPA path (`/search`)

- Mode: **Search Zones** (`parkingType=1`)
- Params (SPA saga): `parkingType` + `upper` + `lower` only (`encodeURI`, raw commas)
- Companion: `/api/zones/search/transient?…`
- Reserve map uses `parkingType=2` — ignore for zone flow
- List **Park Here** → `/zone/start?internalZoneCode={internal}`
- Example: Zone # `1972` → `internalZoneCode=1081972`

### Working manual type-in path (`/zone/start`)

User typed signage codes; SPA resolved via proxy:

| Call | Result |
|------|--------|
| `GET /api/proxy/parkmobileapi/zones/47039` | Hoboken `signageCode=47039`, `internalZoneCode=30447039` |
| `GET /api/proxy/parkmobileapi/zoneoptions/30447039` | duration type |
| `GET /api/zones/30447039` | parkInfo + hour/minute selections |
| `GET /api/proxy/parkmobileapi/price/30447039?timeBlockId=-1&timeBlockQuantity=…` | pricing |

Duration options (Hoboken): hours `0/1/2`, minutes include `20,40` (and `0` at 1h+) — cap automation at **100 minutes** → **1h 40m**.

## What to export for refinement

When you run the NJ `/search` flow in-app, pull `http://<phone-ip>:8765/xhr.txt` and confirm:

1. SPA `zones/search` **200** after Get user location (not our 422 fetch)
2. `pickZone #… internal=…` in logs
3. Navigation to `/zone/start?internalZoneCode=…`
