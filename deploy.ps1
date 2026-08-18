#Requires -Version 5.1
<#
.SYNOPSIS
  Prepare WebAutoParking.ipa and paste it to iCloud Drive Downloads (AltStore).

.DESCRIPTION
  Neighbors such as ios_3d_loop_segments use deploy.ps1 for the build/fetch step,
  then copy-to-icloud.ps1 for the stamp + prune + paste. This repo already has the
  IPA at ios\build artifacts\ipa\WebAutoParking.ipa; deploy.ps1 reuses
  copy-to-icloud.ps1 for that paste (inject BookingConfig, unique filename).

  Deploy workflow:
    1. Build/download IPA (gh workflow / Actions artifact)
    2. Run:  .\deploy.ps1   (calls copy-to-icloud.ps1; also starts AltServer unless
       -SkipAltStorePrep; phone subnet is USB plug-in)
    3. On iPhone: AltStore -> My Apps -> + -> pick the timestamped IPA from
       Files -> iCloud Drive -> Downloads
       Or AltServer Sideload of ios\build artifacts\ipa\WebAutoParking.prepared.ipa

  Re-paste only (stamped IPA name, no extra wrapper): .\copy-to-icloud.ps1

.PARAMETER SkipAltStorePrep
  Do not start AltServer / Clash multicast prep (env_setup). Phone-subnet
  check is USB plug-in, not this script.

.PARAMETER NoWaitEnter
  Do not wait for Enter (child callers). Direct run waits, including on errors.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\deploy.ps1

.EXAMPLE
  .\deploy.ps1 -SkipAltStorePrep
#>
param(
    [switch] $SkipAltStorePrep,
    [switch] $NoWaitEnter
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$CopyScript = Join-Path $ProjectRoot "copy-to-icloud.ps1"

function Wait-EnterToClose {
    if ($NoWaitEnter) { return }
    Write-Host ""
    Write-Host 'Press Enter to close...' -ForegroundColor Yellow
    try {
        [void][Console]::ReadLine()
    } catch {
        Read-Host | Out-Null
    }
}

function Exit-WithEnter {
    param([int] $ExitCode = 0)
    Wait-EnterToClose
    exit $ExitCode
}

trap {
    Write-Host ""
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($NoWaitEnter) { throw $_ }
    Wait-EnterToClose
    exit 1
}

function Write-Step($Message) {
    Write-Host "==> $Message"
}

function Invoke-ProjectAltStoreDeployPrep {
    if ($SkipAltStorePrep) { return }
    $join = @(
        (Join-Path $ProjectRoot 'env_setup\altserver_refresh\Join-AltStoreDeployPrep.ps1')
        (Join-Path $ProjectRoot 'env_setup\altserver_refresh_scripts\Join-AltStoreDeployPrep.ps1')
        'P:\all_scripts\iOS apps\env_setup\altserver_refresh\Join-AltStoreDeployPrep.ps1'
        'P:\all_scripts\iOS apps\env_setup\altserver_refresh_scripts\Join-AltStoreDeployPrep.ps1'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $join) {
        Write-Host 'WARN: env_setup AltServer helpers not found - skip tray prep.'
        return
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        . $join
        Invoke-AltStoreDeployPrep -SkipPhoneSubnet
    } catch {
        Write-Warning ("AltStore deploy prep failed (IPA copy already done): {0}" -f $_.Exception.Message)
    } finally {
        $ErrorActionPreference = $prev
    }
}

if (-not (Test-Path -LiteralPath $CopyScript)) {
    throw "copy-to-icloud.ps1 not found: $CopyScript"
}

Write-Host ""
Write-Host "Deploy workflow:"
Write-Host "  [PC]  1. This script (inject BookingConfig + copy IPA via copy-to-icloud.ps1)"
Write-Host "  [PC]     AltServer tray (env_setup); phone subnet is USB plug-in. -SkipAltStorePrep to skip tray"
Write-Host "  [YOU] 2. iPhone Files -> iCloud Drive -> Downloads -> WebAutoParking-b{build}-{time}.ipa"
Write-Host "  [YOU] 3. AltStore -> My Apps -> + -> select the IPA"
Write-Host ""

Write-Step "Pasting IPA to iCloud (copy-to-icloud)"
& $CopyScript -SkipAltStorePrep -NoWaitEnter
if ($null -ne $LASTEXITCODE -and [int]$LASTEXITCODE -ne 0) {
    throw ("copy-to-icloud.ps1 failed (exit {0})" -f $LASTEXITCODE)
}

Invoke-ProjectAltStoreDeployPrep
Exit-WithEnter 0
