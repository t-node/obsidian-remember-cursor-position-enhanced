<#
.SYNOPSIS
  Keep the Syncthing app alive on the Android devices (so the phone/tablet never strand their cursor
  changes). Applies every OS-level "don't kill this app" setting adb can reach, to each connected device.

.DESCRIPTION
  The #1 cause of "my phone isn't syncing" is Samsung killing the Syncthing-Fork app. This relaxes the
  Android-level restrictions: doze whitelist, RUN_ANY_IN_BACKGROUND, standby bucket = active, global app
  standby + adaptive battery off — and (re)starts the app. Re-run whenever a device is connected (some
  settings can drift after updates/reboots).

  WHAT THIS CANNOT DO (Samsung UI only — do once on each device by hand):
    * Settings -> Battery -> Background usage limits -> "Never sleeping apps" -> add Syncthing
      (and remove it from "Sleeping apps" / "Deep sleeping apps")
    * Syncthing app -> Settings -> "Start on boot" ON   (so it relaunches after a reboot)
    * Syncthing app -> Run conditions -> "Always run in background" + keep the persistent notification
    * Don't swipe Syncthing out of the Recents list.

.EXAMPLE
  pwsh scripts/keep-android-alive.ps1
#>
[CmdletBinding()]
param([string]$Package = 'com.github.catfriend1.syncthingandroid')

$ErrorActionPreference = 'Stop'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source }
if (-not $adb) { Write-Host 'adb not found.' -ForegroundColor Red; exit 1 }

# Try the known wireless IPs too, so a device on Wi-Fi adb is picked up.
foreach ($ip in @('192.168.29.68:5555','100.96.229.92:5555','100.93.19.49:5555')) { & $adb connect $ip 2>&1 | Out-Null }
$devices = (& $adb devices) | Where-Object { $_ -match '\sdevice$' } | ForEach-Object { ($_ -split '\s+')[0] }
if (-not $devices) { Write-Host 'No adb devices connected.' -ForegroundColor Yellow; exit 0 }

foreach ($d in $devices) {
    # Only act on devices that actually have Syncthing installed.
    $has = & $adb -s $d shell "pm list packages $Package" 2>$null
    if (-not $has) { Write-Host "  SKIP  $d (no $Package)" -ForegroundColor DarkGray; continue }
    Write-Host "== $d : pinning $Package as always-run ==" -ForegroundColor Cyan
    & $adb -s $d shell "dumpsys deviceidle whitelist +$Package" 2>$null | Out-Null
    & $adb -s $d shell "cmd appops set $Package RUN_IN_BACKGROUND allow" 2>$null
    & $adb -s $d shell "cmd appops set $Package RUN_ANY_IN_BACKGROUND allow" 2>$null
    & $adb -s $d shell "am set-inactive $Package false" 2>$null
    & $adb -s $d shell "settings put global app_standby_enabled 0" 2>$null
    & $adb -s $d shell "settings put global adaptive_battery_management_enabled 0" 2>$null
    & $adb -s $d shell "monkey -p $Package -c android.intent.category.LAUNCHER 1" 2>$null | Out-Null
    Start-Sleep -Seconds 2
    $bucket = (& $adb -s $d shell "am get-standby-bucket $Package" 2>$null)
    $bg = (& $adb -s $d shell "cmd appops get $Package RUN_ANY_IN_BACKGROUND" 2>$null)
    $procId = (& $adb -s $d shell "pidof $Package" 2>$null)
    Write-Host ("  bucket={0} background={1} running={2}" -f $bucket, ($bg -replace 'RUN_ANY_IN_BACKGROUND: ',''), [bool]$procId) -ForegroundColor Green
}

Write-Host "`nReminder: also do the Samsung 'Never sleeping apps' + Syncthing 'Start on boot' steps by hand (see this script's header) — adb can't set those, and they're what survive a reboot." -ForegroundColor Yellow
