# Build and install without a Mac

Same approach as [`ios_3d_loop_segments`](../../ios_3d_loop_segments/ios/BUILD-WITHOUT-MAC.md): compile an IPA in the cloud, sideload on Windows. Prefer **SideStore nightly** when AltStore (or SideStore stable) shows **incorrect data format**; otherwise AltStore + AltServer is fine.

## Get an IPA

1. Push this repo to GitHub.
2. **Actions** → **ios-build** → **Run workflow**.
3. Download artifact **`WebAutoParking-ipa`** → `ios/build artifacts/ipa/WebAutoParking.ipa`.
4. Optional: copy to iCloud for the phone:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
# paste-only (same iCloud step):
.\copy-to-icloud.ps1
```

`deploy.ps1` reuses `copy-to-icloud.ps1` (same split as Loop Segments). That helper injects local `BookingConfig.json`, strips `_CodeSignature` so SideStore / AltStore can re-sign, prunes older `WebAutoParking*.ipa` in iCloud Downloads, then copies a timestamped `WebAutoParking-b{build}-{yyyyMMdd-HHmmss}.ipa` to `%USERPROFILE%\iCloudDrive\Downloads` (or `C:\Users\dsouzaankit\iCloudDrive\Downloads` when present).

Optional signed builds: set secrets `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`. Without them the IPA is unsigned and the store re-signs with your Apple ID.

Workflow: [`.github/workflows/ios-build.yml`](../.github/workflows/ios-build.yml).

App icon: same packaging as Loop Segments — single `AppIcon.appiconset/AppIcon.png` (1024), `CFBundleIconName`, `TARGETED_DEVICE_FAMILY: "1,2"`, catalog via main target sources (not a separate `resources` entry). After icon changes: **delete Parking on the phone**, then install the new IPA (SpringBoard/Control Center cache blanks).

## Install (SideStore nightly — preferred when AltStore flakes)

Full SideStore setup + troubleshooting (iloader, LocalDevVPN, pairing, free 3-app slots, sign-in 503): shared [env_setup/sidestore/README.md](../../env_setup/sidestore/README.md). Official: [docs.sidestore.io](https://docs.sidestore.io/docs/installation/prerequisites).

Prefer **nightly** (stable and AltStore hit *incorrect data format* here). SideStore + Parking + Loop Segments fills the free ID's **3** app slots, so delete AltStore if you switch.

1. Wait until Files shows the **full size** IPA (no iCloud stub).
2. **LocalDevVPN → Connect**.
3. **SideStore → My Apps → +** → pick the timestamped IPA (or Files → Share → SideStore).
4. **Settings → General → VPN & Device Management** → Trust your Apple ID (first install).
5. **Refresh:** LocalDevVPN on → **7 DAYS** / Refresh in SideStore, no PC (optional [Shortcuts auto-refresh](../../env_setup/sidestore/README.md#sidestore-shortcuts-auto-refresh-optional)).

## Install (AltStore)

1. AltServer on PC + AltStore on phone (same Wi‑Fi; free Apple ID).
2. On the **iPhone**: **AltStore → My Apps → +** → pick the timestamped IPA from iCloud Downloads. **invalid format** / **incorrect format** is often a partial iCloud sync or flaky signing — wait for full size, retry; if it never installs, use **SideStore nightly** (above) or **AltServer → Sideload** the same file from the PC.
3. Wait until Files shows the **full size** before installing from iCloud.
4. **Settings → General → VPN & Device Management** → Trust your Apple ID (first install).
5. Free Apple ID cert lasts ~7 days — **Refresh** in AltStore before expiry (no new IPA; retry if that flakes — same error string, different cause).

Full AltStore / AltServer / Wi‑Fi troubleshooting: shared [env_setup/altserver_refresh/ALTSTORE.md](../../env_setup/altserver_refresh/ALTSTORE.md). Sideloadly: Loop Segments [BUILD-WITHOUT-MAC.md](../../ios_3d_loop_segments/ios/BUILD-WITHOUT-MAC.md#5-sideloadly-last-resort).

## Local Mac (optional)

```bash
brew install xcodegen
cd ios && xcodegen generate && open WebAutoParking.xcodeproj
```

Sign with Personal Team → Run, or Archive → Development IPA.
