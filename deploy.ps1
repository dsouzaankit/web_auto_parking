# Copy WebAutoParking.ipa to iCloud Drive Downloads for phone install (AltStore).
#
# Prerequisites: IPA already built/downloaded to ios\build artifacts\ipa\
#
# Deploy workflow:
#   1. Build/download IPA (gh workflow / Actions artifact)
#   2. Run:  .\deploy.ps1
#   3. On iPhone: AltStore -> My Apps -> + -> pick WebAutoParking.ipa from
#      Files -> iCloud Drive -> Downloads (or share from Files into AltStore)
#
# Usage:  powershell -ExecutionPolicy Bypass -File .\deploy.ps1
# Non-interactive — runs straight through (no Read-Host prompts).

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$IpaName = "WebAutoParking.ipa"
$SourceIpa = Join-Path $ProjectRoot "ios\build artifacts\ipa\$IpaName"
$ICloudDownloads = Join-Path $env:USERPROFILE "iCloudDrive\Downloads"
# Prefer the path the user asked for when present.
$PreferredICloud = "C:\Users\dsouzaankit\iCloudDrive\Downloads"
if (Test-Path -LiteralPath $PreferredICloud) {
    $ICloudDownloads = $PreferredICloud
}
$DestIpa = Join-Path $ICloudDownloads $IpaName

function Write-Step($Message) {
    Write-Host "==> $Message"
}

if (-not (Test-Path -LiteralPath $SourceIpa)) {
    throw "IPA not found: $SourceIpa`nBuild/download it first (Actions -> ios-build -> WebAutoParking-ipa)."
}

if (-not (Test-Path -LiteralPath $ICloudDownloads)) {
    throw "iCloud Downloads folder not found: $ICloudDownloads"
}

Write-Host ""
Write-Host "Deploy workflow:"
Write-Host "  [PC]  1. This script (copy IPA to iCloud Downloads)"
Write-Host "  [YOU] 2. iPhone Files -> iCloud Drive -> Downloads -> $IpaName"
Write-Host "  [YOU] 3. AltStore -> My Apps -> + -> select the IPA"
Write-Host ""

Write-Step "Removing old $IpaName from $ICloudDownloads"
if (Test-Path -LiteralPath $DestIpa) {
    Write-Host "    removing $DestIpa"
    Remove-Item -LiteralPath $DestIpa -Force
}

Write-Step "Copying IPA to iCloud Downloads"
Copy-Item -LiteralPath $SourceIpa -Destination $DestIpa -Force

$src = Get-Item -LiteralPath $SourceIpa
$dst = Get-Item -LiteralPath $DestIpa
$SizeKb = [math]::Round($dst.Length / 1KB, 1)

Write-Host ""
Write-Host "Done. $DestIpa ($SizeKb KB)"
Write-Host "Source: $SourceIpa"
Write-Host "Source mtime: $($src.LastWriteTime)"
Write-Host ""
Write-Host "Next on iPhone:"
Write-Host "  Wait for iCloud to sync Downloads"
Write-Host "  AltStore -> My Apps -> + -> $IpaName"
Write-Host "  Or Files -> iCloud Drive -> Downloads -> share/open in AltStore"
