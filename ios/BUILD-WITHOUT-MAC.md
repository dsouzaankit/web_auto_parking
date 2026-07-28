# Build and install without a Mac

Same approach as [`ios_3d_loop_segments`](../../ios_3d_loop_segments/ios/BUILD-WITHOUT-MAC.md): compile an IPA in the cloud, sideload with **AltStore** on Windows.

## Get an IPA

1. Push this repo to GitHub.
2. **Actions** → **ios-build** → **Run workflow**.
3. Download artifact **`WebAutoParking-ipa`** → `WebAutoParking.ipa`.

Optional signed builds: set secrets `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`. Without them the IPA is unsigned and AltStore re-signs with your Apple ID.

Workflow: [`.github/workflows/ios-build.yml`](../.github/workflows/ios-build.yml).

## Install (AltStore)

1. AltServer on PC + AltStore on phone (same Wi‑Fi; free Apple ID).
2. On the **iPhone**: **AltStore → My Apps → +** → pick `WebAutoParking.ipa` (not AltServer “Sideload” on PC if you want refresh).
3. **Settings → General → VPN & Device Management** → Trust your Apple ID (first install).
4. Free Apple ID cert lasts ~7 days — refresh in AltStore before expiry.

Full AltStore / Wi‑Fi troubleshooting: see the Loop Segments [BUILD-WITHOUT-MAC.md](../../ios_3d_loop_segments/ios/BUILD-WITHOUT-MAC.md).

## Local Mac (optional)

```bash
brew install xcodegen
cd ios && xcodegen generate && open WebAutoParking.xcodeproj
```

Sign with Personal Team → Run, or Archive → Development IPA.
