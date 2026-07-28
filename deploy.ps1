# Copy WebAutoParking.ipa to iCloud Drive Downloads for phone install (AltStore).
#
# Prerequisites: IPA already built/downloaded to ios\build artifacts\ipa\
#
# Deploy workflow:
#   1. Build/download IPA (gh workflow / Actions artifact)
#   2. Run:  .\deploy.ps1
#   3. On iPhone: AltStore -> My Apps -> + -> pick the timestamped IPA from
#      Files -> iCloud Drive -> Downloads (or share from Files into AltStore)
#
# Usage:  powershell -ExecutionPolicy Bypass -File .\deploy.ps1
# Non-interactive — runs straight through (no Read-Host prompts).
#
# Also injects local ios\WebAutoParking\Resources\BookingConfig.json into the IPA
# so CI builds (which ship BookingConfig.example.json) use your real prefill data.

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseIpaName = "WebAutoParking.ipa"
$SourceIpa = Join-Path $ProjectRoot "ios\build artifacts\ipa\$BaseIpaName"
$LocalBookingConfig = Join-Path $ProjectRoot "ios\WebAutoParking\Resources\BookingConfig.json"
$ICloudDownloads = Join-Path $env:USERPROFILE "iCloudDrive\Downloads"
# Prefer the path the user asked for when present.
$PreferredICloud = "C:\Users\dsouzaankit\iCloudDrive\Downloads"
if (Test-Path -LiteralPath $PreferredICloud) {
    $ICloudDownloads = $PreferredICloud
}
$ProjectSpecPath = Join-Path $ProjectRoot "ios\project.yml"
$BuildNumber = "unknown"
if (Test-Path -LiteralPath $ProjectSpecPath) {
    $match = Select-String -Path $ProjectSpecPath -Pattern 'CURRENT_PROJECT_VERSION:\s*"?(?<build>\d+)"?' -AllMatches
    if ($match -and $match.Matches.Count -gt 0) {
        $BuildNumber = $match.Matches[0].Groups["build"].Value
    }
}
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$DestIpaName = "WebAutoParking-b$BuildNumber-$Timestamp.ipa"
$DestIpa = Join-Path $ICloudDownloads $DestIpaName
$PreparedIpa = Join-Path $ProjectRoot "ios\build artifacts\ipa\WebAutoParking.prepared.ipa"

function Write-Step($Message) {
    Write-Host "==> $Message"
}

function Inject-BookingConfigIntoIpa {
    param(
        [Parameter(Mandatory = $true)][string]$IpaPath,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$OutPath
    )

    $py = @'
import sys
import zipfile
from pathlib import Path

ipa = Path(sys.argv[1])
config = Path(sys.argv[2])
out = Path(sys.argv[3])

with zipfile.ZipFile(ipa, "r") as src:
    matches = [n for n in src.namelist() if n.endswith("/BookingConfig.json") or n == "BookingConfig.json"]
    if not matches:
        raise SystemExit("BookingConfig.json not found inside IPA")
    member_name = matches[0]
    cfg_bytes = config.read_bytes()
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as dst:
        replaced = False
        for info in src.infolist():
            data = cfg_bytes if info.filename == member_name else src.read(info.filename)
            if info.filename == member_name:
                replaced = True
            dst.writestr(info, data)
    if not replaced:
        raise SystemExit(f"failed to replace {member_name}")
print(f"injected {config.name} -> {member_name}")
'@

    $tmpPy = Join-Path $env:TEMP "wap_inject_bookingconfig.py"
    Set-Content -LiteralPath $tmpPy -Value $py -Encoding UTF8
    & py -3.9 $tmpPy $IpaPath $ConfigPath $OutPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inject BookingConfig.json into IPA"
    }
}

if (-not (Test-Path -LiteralPath $SourceIpa)) {
    throw "IPA not found: $SourceIpa`nBuild/download it first (Actions -> ios-build -> WebAutoParking-ipa)."
}

if (-not (Test-Path -LiteralPath $ICloudDownloads)) {
    throw "iCloud Downloads folder not found: $ICloudDownloads"
}

Write-Host ""
Write-Host "Deploy workflow:"
Write-Host "  [PC]  1. This script (inject BookingConfig + copy IPA to iCloud Downloads)"
Write-Host "  [YOU] 2. iPhone Files -> iCloud Drive -> Downloads -> $DestIpaName"
Write-Host "  [YOU] 3. AltStore -> My Apps -> + -> select the IPA"
Write-Host ""

$IpaToCopy = $SourceIpa
if (Test-Path -LiteralPath $LocalBookingConfig) {
    Write-Step "Injecting local BookingConfig.json into IPA"
    if (Test-Path -LiteralPath $PreparedIpa) {
        Remove-Item -LiteralPath $PreparedIpa -Force
    }
    Inject-BookingConfigIntoIpa -IpaPath $SourceIpa -ConfigPath $LocalBookingConfig -OutPath $PreparedIpa
    $IpaToCopy = $PreparedIpa
} else {
    Write-Host "WARNING: local BookingConfig.json missing - IPA keeps CI example config"
    Write-Host "         expected: $LocalBookingConfig"
}

Write-Step "Deleting older WebAutoParking IPA files from iCloud Downloads"
$OldIpas = Get-ChildItem -LiteralPath $ICloudDownloads -Filter "WebAutoParking*.ipa" -File -ErrorAction SilentlyContinue
foreach ($old in $OldIpas) {
    if ($old.Name -ne $DestIpaName) {
        Write-Host "    removing $($old.FullName)"
        Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-Step "Copying IPA to iCloud Downloads"
Copy-Item -LiteralPath $IpaToCopy -Destination $DestIpa -Force

$src = Get-Item -LiteralPath $IpaToCopy
$dst = Get-Item -LiteralPath $DestIpa
$SizeKb = [math]::Round($dst.Length / 1KB, 1)

Write-Host ""
Write-Host ("Done. {0} ({1} KB)" -f $DestIpa, $SizeKb)
Write-Host "Source: $IpaToCopy"
Write-Host "Source mtime: $($src.LastWriteTime)"
Write-Host "Build: $BuildNumber"
if (Test-Path -LiteralPath $LocalBookingConfig) {
    Write-Host "BookingConfig: local personal config injected"
}
Write-Host ""
Write-Host "Next on iPhone:"
Write-Host "  Wait for iCloud to sync Downloads"
Write-Host "  AltStore -> My Apps -> + -> $DestIpaName"
Write-Host "  Or Files -> iCloud Drive -> Downloads -> share/open in AltStore"
