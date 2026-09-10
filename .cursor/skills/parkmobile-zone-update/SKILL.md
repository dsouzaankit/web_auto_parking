---
name: parkmobile-zone-update
description: >-
  Diagnose and adapt Web Auto Parking when ParkMobile Zone SPA/API/UI changes
  break automation (v2 checkout paths, testids, duration chips, guest error
  flash, Receipts/Attempted capture). Use when Zone stalls, selectors miss,
  receipts stay empty after pay, Park here races, or the user reports a
  ParkMobile flow update / redesign.
---

# ParkMobile Zone update loop

When ParkMobile’s Zone web flow changes, do **not** rewrite from memory. Pull live evidence, diff against code, fix narrowly, document, then ship only if asked.

## Checklist

Copy and track:

```
ParkMobile Zone update:
- [ ] 1. Reproduce / gather symptom
- [ ] 2. Pull live LAN evidence
- [ ] 3. Diff live vs code (paths, testids, XHR)
- [ ] 4. Classify break (route / selector / API / race / receipts)
- [ ] 5. Patch + README quirk notes
- [ ] 6. Ship IPA only if user asks (IPA to icloud / IPA to cloud)
```

## Step 1 — Symptom

Ask or infer which step failed: search → zone-details → guest → vehicle → duration → confirm → pay → Receipts/Attempted.

Hard rules already in product:
- Prefer `data-testid` / `data-pmtest-id` over visible copy.
- Confirm: select Apple Pay **method only** — never tap `apple-pay-button` / complete purchase.
- Internal zone codes are **7+ digits**; public Zone # is 4–6 digit signage (e.g. `47922`).

## Step 2 — Pull live evidence

Phone + PC on same Wi‑Fi; app LAN server on `:8765`.

```powershell
py -3 "ai/parkmobile_zone_xhr/_pull_live.py"
```

Optional: `py -3 ai/parkmobile_zone_xhr/_pull_live.py --base http://<phone-ip>:8765`

Reads into (often **gitignored** under `ai/`):
- `ai/parkmobile_zone_xhr/live_logs.txt` — `v2ParkingDiag`, `Prefill JS`, settle / Try again
- `ai/parkmobile_zone_xhr/live_xhr.txt` — purchase / parking / tariff APIs
- `ai/parkmobile_zone_xhr/live_hooks.txt` — DOM hooks / idle reasons
- Optional HTML dump via phone `/html` if selectors are unknown

Also skim `README.md` Zone flow notes for known quirks before inventing new ones.

## Step 3 — Diff live vs code

Primary files:
| Area | File |
|------|------|
| Prefill / v2 steps | `ios/WebAutoParking/Models/BookingFormPrefill.swift` |
| Receipts | `ios/WebAutoParking/Models/ParkingSessionStore.swift` |
| Attempted | `ios/WebAutoParking/Models/AttemptedZoneStore.swift` |
| Jump URLs | `ios/WebAutoParking/Models/Garage.swift` (`FixedDurationURLs`) |
| WebView capture hooks | `ios/WebAutoParking/Views/ParkingWebView.swift` |

Compare:
1. **Routes** in logs (`WebView URL changed`, `v2ParkingDiag step=`) vs `v2ParkingStep()`
2. **Testids** in hooks/HTML vs selectors in prefill
3. **XHR** purchase/parking/tariff shapes vs `ParkingSessionStore` / duration tariff parsing
4. **Races** — Park here before pricing → guest “An error occurred”

Known baseline snapshot: [reference.md](reference.md).

## Step 4 — Classify + fix

| Break | Typical fix |
|-------|-------------|
| New path under `/v2/parking/…` | Extend `v2ParkingStep` + advance branch; keep legacy `/zone/…` fallback |
| Renamed testid / chip | Update selectors; keep text fallback |
| Duration options changed | Re-map hours/minutes chips + tariff `timebasedOptions`; only Continue when shown ≈ target |
| Guest error flash | Settle wait on zone-details (pricing / ~2.8s) before **auto** Park here (Attempted); search nearest uses manual confirm; dismiss overlay / **Try again**; recover `areaNo` |
| Wrong zone after nearest pick | After geo/address pick, set `sessionStorage` confirm flag **before** nav, then pause on zone-details (`awaitManualZoneConfirm`); Attempted jumps (fresh WebView) auto-continue |
| Empty Receipts after pay | Capture v2 purchase + `GET …/api/parking/{uuid}` + `/v2/parking/session/guest/{uuid}` (not only legacy `/sessions/`) |
| Attempted polluted by pay | Ignore v2 session/purchase paths in `AttemptedZoneStore.shouldIgnore` |
| Jump opens wrong city | Jump with **internal** `areaNo` only → `/v2/parking/zone-details?areaNo=` |

Keep patches local to the broken step. Do not “clean up” unrelated prefill.

## Step 5 — README

Update Zone flow notes when behavior or recovery changes (error flash, new capture URLs, duration rules). Do not invent TODOs.

## Step 6 — Ship (only on request)

Phrase: **IPA to icloud** / **IPA to cloud**.

1. Bump `CURRENT_PROJECT_VERSION` in `ios/project.yml`
2. Commit + `git push origin master` (use `git -c safe.directory=…` if needed on this machine)
3. `gh workflow run ios-build.yml --repo dsouzaankit/web_auto_parking --ref master`
4. `gh run watch …` → `gh run download … --name WebAutoParking-ipa --dir "ios/build artifacts/ipa"`
5. `.\deploy.ps1 -NoWaitEnter`

Docs-only commits: push without IPA unless asked.

## Anti-patterns

- Guessing new ParkMobile selectors without live hooks/XHR/HTML
- Treating public Zone # as `internalZoneCode` / `areaNo`
- Auto-completing Apple Pay purchase
- Shipping an IPA without an explicit ship phrase
- Writing Attempted from `/zones/search` map lists
