<#
  sync-now.ps1 — FORCE an immediate Syncthing sync across everything reachable.

  Syncthing already auto-syncs within ~1-2s on the LAN (fsWatcher). This button is for when you
  want to force it RIGHT NOW: it rescans the hub's folder (pushes the laptop's latest immediately)
  and taps "RESCAN ALL" on every ADB-reachable Android device (pushes theirs immediately). Any
  connected peer then converges within a couple of seconds.

  Note: a device that's away / not on ADB just syncs on its own fsWatcher — or tap RESCAN ALL in
  its own Syncthing app. There is no truly "synchronous everywhere" in Syncthing (it's
  device-by-device, eventually-consistent) — this makes it as close to instant as possible.

  No elevation needed.
#>
$key = "DGutrUqQGvPgZPxdxaR9YY9UwNpd7d4r"
$folder = "515yk-rnqru"
$base = "http://127.0.0.1:8384/rest"
$h = @{ 'X-API-Key' = $key }

Write-Host "=== SYNC NOW ===" -ForegroundColor Cyan

# 1. Hub: rescan now (pushes the laptop's latest to all connected peers)
try {
  Invoke-RestMethod "$base/db/scan?folder=$folder" -Method Post -Headers $h -TimeoutSec 20 | Out-Null
  Write-Host "  hub (laptop): rescan triggered" -ForegroundColor Green
} catch {
  Write-Host "  hub rescan FAILED — is Syncthing running? ($($_.Exception.Message))" -ForegroundColor Red
}

# 2. Android devices on ADB: force RESCAN ALL so they push their changes immediately
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) { $adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" }
$pkg = "com.github.catfriend1.syncthingandroid"
if (Test-Path $adb) {
  $devs = & $adb devices | Select-String "device$" | ForEach-Object { ($_ -split "\s+")[0] } | Where-Object { $_ -and $_ -ne 'List' }
  if ($devs) {
    foreach ($d in $devs) {
      & $adb -s $d shell "monkey -p $pkg -c android.intent.category.LAUNCHER 1" *> $null
      Start-Sleep -Milliseconds 1500
      & $adb -s $d shell input tap 1069 82 *> $null   # 'RESCAN ALL' (Syncthing-Fork top bar, landscape)
      Write-Host "  android $($d): RESCAN ALL tapped" -ForegroundColor Green
    }
  } else { Write-Host "  no Android devices on ADB (they'll sync on their own / tap RESCAN ALL in-app)" -ForegroundColor DarkGray }
} else {
  Write-Host "  adb not found; skipped Android devices" -ForegroundColor DarkGray
}

# 3. Show connected peers
Start-Sleep -Seconds 2
try {
  $c = Invoke-RestMethod "$base/system/connections" -Headers $h -TimeoutSec 8
  $n = @($c.connections.PSObject.Properties | Where-Object { $_.Value.connected }).Count
  Write-Host "`n  connected peers: $n — converging now (a few seconds)." -ForegroundColor Cyan
} catch {}
