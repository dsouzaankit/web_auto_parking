# Copy WebAutoParking.ipa to iCloud Drive Downloads for phone install (AltStore).
#
# Prerequisites: IPA already built/downloaded to ios\build artifacts\ipa\
#
# Deploy workflow:
#   1. Build/download IPA (gh workflow / Actions artifact)
#   2. Run:  .\deploy.ps1
#   3. On iPhone: AltStore -> My Apps -> + -> pick WebAutoParking.ipa from
#      Files -> iCloud Drive -> Downloads
#      Or AltServer Sideload of ios\build artifacts\ipa\WebAutoParking.prepared.ipa
#
# Usage:  powershell -ExecutionPolicy Bypass -File .\deploy.ps1

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BaseIpaName = "WebAutoParking.ipa"
$SourceIpa = Join-Path $ProjectRoot "ios\build artifacts\ipa\$BaseIpaName"
$LocalBookingConfig = Join-Path $ProjectRoot "ios\WebAutoParking\Resources\BookingConfig.json"
$ICloudDownloads = Join-Path $env:USERPROFILE "iCloudDrive\Downloads"
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
$DestIpaName = "WebAutoParking.ipa"
$DestIpa = Join-Path $ICloudDownloads $DestIpaName
$PreparedIpa = Join-Path $ProjectRoot "ios\build artifacts\ipa\WebAutoParking.prepared.ipa"

function Write-Step($Message) {
    Write-Host "==> $Message"
}

function Remove-ICloudIpas {
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [string]$KeepName = ""
    )

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $all = @(Get-ChildItem -LiteralPath $Folder -Filter "WebAutoParking*.ipa" -File -Force -ErrorAction SilentlyContinue)
        $targets = @($all | Where-Object { $_.Name -ne $KeepName })
        if ($targets.Count -eq 0) { return @() }
        foreach ($old in $targets) {
            Write-Host "    removing $($old.FullName) (try $attempt)"
            try {
                attrib -R -S -H $old.FullName 2>$null
                Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop
            } catch {
                Write-Host "    WARN: $($_.Exception.Message)"
            }
        }
        Start-Sleep -Milliseconds (400 * $attempt)
        $remaining = @(Get-ChildItem -LiteralPath $Folder -Filter "WebAutoParking*.ipa" -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $KeepName })
        if ($remaining.Count -eq 0) { return @() }
    }
    return @(Get-ChildItem -LiteralPath $Folder -Filter "WebAutoParking*.ipa" -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $KeepName })
}

function Inject-BookingConfigIntoIpa {
    param(
        [Parameter(Mandatory = $true)][string]$IpaPath,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$OutPath
    )

    # .NET ZipArchive CreateEntry leaves Unix mode 000 on the new file -> AltStore
    # "don't have permission". Python zipfile can set external_attr (0644 / 0755).
    $py = @'
import sys
import zipfile
from pathlib import Path

ipa = Path(sys.argv[1])
config = Path(sys.argv[2])
out = Path(sys.argv[3])

ATTR_FILE = 0x81A40000  # regular file 0644
ATTR_EXEC = 0x81ED0000  # regular file 0755
ATTR_DIR = 0x41ED0010   # directory 0755

def copy_info(src_info, filename=None):
    info = zipfile.ZipInfo(filename=filename or src_info.filename, date_time=src_info.date_time)
    info.compress_type = src_info.compress_type
    info.create_system = 3  # Unix
    info.external_attr = src_info.external_attr
    if info.filename.endswith("/"):
        info.compress_type = zipfile.ZIP_STORED
        if (info.external_attr >> 16) == 0:
            info.external_attr = ATTR_DIR
    elif (info.external_attr >> 16) == 0:
        info.external_attr = ATTR_FILE
    return info

with zipfile.ZipFile(ipa, "r") as src:
    matches = [n for n in src.namelist() if n.endswith("/BookingConfig.json") or n == "BookingConfig.json"]
    if not matches:
        raise SystemExit("BookingConfig.json not found inside IPA")
    member_name = matches[0]
    cfg_bytes = config.read_bytes()
    if out.exists():
        out.unlink()
    with zipfile.ZipFile(out, "w") as dst:
        replaced = False
        stripped = 0
        for info in src.infolist():
            name = info.filename
            if "_CodeSignature" in name:
                stripped += 1
                continue
            if name == member_name:
                new_info = zipfile.ZipInfo(filename=member_name, date_time=info.date_time)
                new_info.compress_type = zipfile.ZIP_DEFLATED
                new_info.create_system = 3
                new_info.external_attr = ATTR_FILE
                dst.writestr(new_info, cfg_bytes)
                replaced = True
                continue
            data = src.read(name)
            dst.writestr(copy_info(info), data)
        if not replaced:
            raise SystemExit(f"failed to replace {member_name}")
with zipfile.ZipFile(out, "r") as check:
    bad = check.testzip()
    if bad is not None:
        raise SystemExit(f"prepared IPA failed CRC check: {bad}")
    for info in check.infolist():
        if info.filename.endswith("/"):
            continue
        mode = (info.external_attr >> 16) & 0o777
        if mode == 0:
            raise SystemExit(f"entry has Unix mode 000 (AltStore permission error): {info.filename}")
print(f"injected {config.name} -> {member_name}; stripped {stripped} signature entries")
'@

    $tmpPy = Join-Path $env:TEMP "wap_inject_bookingconfig.py"
    # ASCII-only script; UTF8 no BOM avoids PowerShell/Python surprises
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmpPy, $py, $utf8NoBom)
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
    Inject-BookingConfigIntoIpa -IpaPath $SourceIpa -ConfigPath $LocalBookingConfig -OutPath $PreparedIpa
    $IpaToCopy = $PreparedIpa
} else {
    Write-Host "WARNING: local BookingConfig.json missing - IPA keeps CI example config"
    Write-Host "         expected: $LocalBookingConfig"
}

Write-Step "Removing older WebAutoParking*.ipa from iCloud Downloads"
$leftover = Remove-ICloudIpas -Folder $ICloudDownloads -KeepName ""
if ($leftover.Count -gt 0) {
    Write-Host "ERROR: could not delete:"
    foreach ($f in $leftover) { Write-Host "  $($f.FullName)" }
    throw "iCloud still has old IPAs. Close Files/AltStore, delete them manually, re-run deploy."
}

Write-Step "Copying IPA to iCloud Downloads as $DestIpaName (build $BuildNumber)"
Copy-Item -LiteralPath $IpaToCopy -Destination $DestIpa -Force

$leftover = Remove-ICloudIpas -Folder $ICloudDownloads -KeepName $DestIpaName
if ($leftover.Count -gt 0) {
    Write-Host "WARNING: leftover IPAs still present (iCloud may restore them):"
    foreach ($f in $leftover) { Write-Host "  $($f.FullName)" }
}

$src = Get-Item -LiteralPath $IpaToCopy
$dst = Get-Item -LiteralPath $DestIpa
$SizeKb = [math]::Round($dst.Length / 1KB, 1)

Write-Host ""
Write-Host ("Done. {0} ({1} KB)" -f $DestIpa, $SizeKb)
Write-Host "Source: $IpaToCopy"
Write-Host "Source mtime: $($src.LastWriteTime)"
Write-Host "Build: $BuildNumber"
if (Test-Path -LiteralPath $LocalBookingConfig) {
    Write-Host "BookingConfig: injected with Unix mode 0644; _CodeSignature stripped"
}
Write-Host ""
Write-Host "Next on iPhone:"
Write-Host "  Wait until Files shows full size (~$SizeKb KB)"
Write-Host "  AltStore -> My Apps -> + -> $DestIpaName"
Write-Host "  Or AltServer Sideload: $IpaToCopy"
