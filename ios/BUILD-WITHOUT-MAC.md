# Build and install without a Mac

Same approach as [`ios_3d_loop_segments`](../../ios_3d_loop_segments/ios/BUILD-WITHOUT-MAC.md): compile an IPA in the cloud, sideload with **AltStore** on Windows.

## Get an IPA

1. Push this repo to GitHub.
2. **Actions** → **ios-build** → **Run workflow**.
3. Download artifact **`WebAutoParking-ipa`** → `ios/build artifacts/ipa/WebAutoParking.ipa`.
4. Optional: copy to iCloud for the phone:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```

That copies a timestamped `WebAutoParking-b{build}-{yyyyMMdd-HHmmss}.ipa` to `%USERPROFILE%\iCloudDrive\Downloads` (or `C:\Users\dsouzaankit\iCloudDrive\Downloads` when present), injects local `BookingConfig.json`, strips `_CodeSignature` so AltStore can re-sign, and removes older `WebAutoParking*.ipa` copies.

Optional signed builds: set secrets `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`. Without them the IPA is unsigned and AltStore re-signs with your Apple ID.

Workflow: [`.github/workflows/ios-build.yml`](../.github/workflows/ios-build.yml).

App icon: same packaging as Loop Segments — single `AppIcon.appiconset/AppIcon.png` (1024), `CFBundleIconName`, `TARGETED_DEVICE_FAMILY: "1,2"`, catalog via main target sources (not a separate `resources` entry). After icon changes: **delete Parking on the phone**, then install the new IPA (SpringBoard/Control Center cache blanks).

## Install (AltStore)

1. AltServer on PC + AltStore on phone (same Wi‑Fi; free Apple ID).
2. On the **iPhone**: **AltStore → My Apps → +** → pick the timestamped IPA from iCloud Downloads. If AltStore says **invalid format** / **incorrect format**: force-quit and reopen AltStore, wait for full iCloud sync, then retry; if it still fails, **AltServer → Sideload** the same file from the PC.
3. Wait until Files shows the **full size** before installing from iCloud.
4. **Settings → General → VPN & Device Management** → Trust your Apple ID (first install).
5. Free Apple ID cert lasts ~7 days — **Refresh** in AltStore before expiry (no new IPA; retry if that flakes — same error string, different cause).

Full AltStore / Wi‑Fi troubleshooting: see the Loop Segments [BUILD-WITHOUT-MAC.md](../../ios_3d_loop_segments/ios/BUILD-WITHOUT-MAC.md).

## Local Mac (optional)

```bash
brew install xcodegen
cd ios && xcodegen generate && open WebAutoParking.xcodeproj
```

Sign with Personal Team → Run, or Archive → Development IPA.
