<#
  sync-now.ps1 — FORCE an immediate Syncthing sync across everything reachable, via clean REST
  rescans (no fragile screen-taps).

  - Hub (laptop): rescan via its local REST API.
  - Each ADB-reachable Android device: adb-forward its Syncthing GUI port and rescan via REST
    (falls back to tapping "RESCAN ALL" in the app if REST isn't reachable).

  Keys/serials come from scripts/sync.config.ps1 (gitignored). With fsWatcherDelayS=1s on every
  device, normal changes already propagate in ~1-2s on their own — this button just forces it now.
#>
$cfgPath = Join-Path $PSScriptRoot 'sync.config.ps1'
if (-not (Test-Path $cfgPath)) { Write-Host "Missing scripts\sync.config.ps1 (Syncthing keys)." -ForegroundColor Red; exit 1 }
. $cfgPath
$hubKey = $SyncConfig.SyncthingHubApiKey
$folder = $SyncConfig.SyncthingFolderId
$hubBase = "http://127.0.0.1:8384/rest"
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) { $adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" }

Write-Host "=== SYNC NOW ===" -ForegroundColor Cyan

# 1. Hub: rescan via REST
try {
  Invoke-RestMethod "$hubBase/db/scan?folder=$folder" -Method Post -Headers @{ 'X-API-Key' = $hubKey } -TimeoutSec 20 | Out-Null
  Write-Host "  hub (laptop): rescan OK" -ForegroundColor Green
} catch { Write-Host "  hub rescan FAILED: $($_.Exception.Message)" -ForegroundColor Red }

# 2. Android devices: clean REST rescan over an adb-forwarded GUI port
if (Test-Path $adb) {
  $online = & $adb devices | Select-String "device$" | ForEach-Object { ($_ -split "\s+")[0] } | Where-Object { $_ -and $_ -ne 'List' }
  foreach ($d in $SyncConfig.SyncthingAndroid) {
    $serial = $online | Where-Object { $_ -eq $d.serial -or $_ -like "*$($d.ip)*" } | Select-Object -First 1
    if (-not $serial) {
      Write-Host "  $($d.name): not on ADB — it auto-syncs on its own (1s watcher), or tap RESCAN ALL in-app" -ForegroundColor DarkGray
      continue
    }
    $lp = $d.localPort
    & $adb -s $serial forward "tcp:$lp" tcp:8384 *> $null
    try {
      Invoke-RestMethod "https://127.0.0.1:$lp/rest/db/scan?folder=$folder" -Method Post -Headers @{ 'X-API-Key' = $d.apikey } -SkipCertificateCheck -TimeoutSec 15 | Out-Null
      Write-Host "  $($d.name): clean REST rescan OK" -ForegroundColor Green
    } catch {
      & $adb -s $serial shell "monkey -p com.github.catfriend1.syncthingandroid -c android.intent.category.LAUNCHER 1" *> $null
      Start-Sleep -Milliseconds 1500
      & $adb -s $serial shell input tap 1069 82 *> $null   # 'RESCAN ALL' fallback
      Write-Host "  $($d.name): REST unavailable, used RESCAN ALL tap" -ForegroundColor Yellow
    } finally {
      & $adb -s $serial forward --remove "tcp:$lp" *> $null
    }
  }
} else { Write-Host "  adb not found; skipped Android devices" -ForegroundColor DarkGray }

Write-Host "`n  Done — connected peers converge within ~1-2s." -ForegroundColor Cyan
