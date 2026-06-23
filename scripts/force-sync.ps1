<#
.SYNOPSIS
  FORCE SYNC — make every reachable device match THIS laptop's vault, right now.

.WHAT IT IS (and isn't)
  This forces an *immediate replication*: the master (this laptop) pushes its current state to
  CouchDB, then every reachable device is forced to pull it now (mobiles only sync in the
  foreground, so we restart + foreground their Obsidian). Online laptops converge on their own
  10s timer, so they don't need kicking.

  This is NOT a hard overwrite/rebuild. It will NOT make the DB lineage identical by force the
  way "Overwrite Remote + Fetch everything" does (see -Hard below / SYNC-RUNBOOK.md §2). Use this
  for the everyday "make sure everyone has my latest NOW". Use the rebuild only to fix divergence.

.PARAMETER RestartMaster  Also restart THIS laptop's Obsidian to force its push (default: just wait
                          for its push to settle; restart is the deterministic hammer).
.PARAMETER Hard           Don't run — print the safe rebuild procedure instead (it needs per-device
                          Fetch taps and can't be fully automated with the current plugins).
.PARAMETER WaitSeconds    How long to let replication run before the convergence check (default 35).

.EXAMPLE
  pwsh scripts/force-sync.ps1            # force all reachable devices to match this laptop
  pwsh scripts/force-sync.ps1 -RestartMaster
#>
[CmdletBinding()]
param([switch]$RestartMaster, [switch]$Hard, [int]$WaitSeconds = 35)
. "$PSScriptRoot\_sync-config.ps1"
$ErrorActionPreference = 'Continue'

if ($Hard) {
  Write-Host @"
HARD override (make every device identical to this laptop by force) = a REBUILD. It is heavy and
semi-manual by design, so it is not automated here. Do it deliberately:
  1) This laptop's Obsidian: Command palette -> 'Self-hosted LiveSync: Overwrite remote'.
  2) Each OTHER device's Obsidian: on the lock dialog choose 'Fetch everything from the remote'.
  3) After every device has fetched:  pwsh scripts\sync-reset.ps1 -Action unlock
See SYNC-RUNBOOK.md section 2. Only needed to resolve divergence — not for routine syncing.
"@ -ForegroundColor Yellow
  return
}

# --- adb resolver ---
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) { $adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" }
if (-not (Test-Path $adb)) { Write-Host "adb not found; can't reach Android devices." -ForegroundColor Red }

$couch = $CouchUrl   # bridge URL (127.0.0.1:5994) from sync.config.ps1
$auth  = @{ Authorization = ("Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$CouchUser`:$CouchPass"))) }
function CouchDb { try { Invoke-RestMethod "$couch/$DbName" -Headers $auth -TimeoutSec 6 } catch { $null } }

Write-Host "=== FORCE SYNC (master = this laptop: $VaultDir) ===" -ForegroundColor Cyan

# 0. CouchDB reachable?
$info = CouchDb
if (-not $info) { Write-Host "CouchDB unreachable at $couch — run scripts\sync-couch-bridge.ps1 first." -ForegroundColor Red; return }
Write-Host ("CouchDB OK (doc_count={0})" -f $info.doc_count) -ForegroundColor Green

# 1. Force the master to push.
if ($RestartMaster) {
  $proc = Get-Process Obsidian -ErrorAction SilentlyContinue | Select-Object -First 1
  $exe = if ($proc) { $proc.Path } else { "$env:LOCALAPPDATA\Obsidian\Obsidian.exe" }
  Get-Process Obsidian -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep -Seconds 2
  if (Test-Path $exe) { Start-Process $exe; Write-Host "master Obsidian restarted (pushing on start)" -ForegroundColor Green }
} else {
  if (-not (Get-Process Obsidian -ErrorAction SilentlyContinue)) {
    Write-Host "WARNING: Obsidian is not running on this laptop — its changes can't push. Open it (or use -RestartMaster)." -ForegroundColor Yellow
  }
}
# Wait for the master's push to settle (update_seq stops climbing = nothing left to push).
$prev = ''; $stable = 0
for ($i = 1; $i -le 20; $i++) {
  $d = CouchDb; $seq = if ($d) { ($d.update_seq -split '-')[0] } else { '' }
  if ($seq -eq $prev -and $seq) { $stable++ } else { $stable = 0 }
  $prev = $seq
  if ($stable -ge 2) { break }
  Start-Sleep -Seconds 2
}
Write-Host "master push settled (update_seq ~$prev)" -ForegroundColor Green

# 2. Force each reachable Android device to pull (re-assert config + restart + foreground).
function Set-SyncFields([string]$raw) {
  $raw = $raw -replace '"liveSync":\s*(true|false)', '"liveSync": false'
  $raw = $raw -replace '"syncOnStart":\s*(true|false)', '"syncOnStart": true'
  $raw = $raw -replace '"syncOnSave":\s*(true|false)', '"syncOnSave": true'
  $raw = $raw -replace '"syncOnFileOpen":\s*(true|false)', '"syncOnFileOpen": true'
  $raw = $raw -replace '"periodicReplication":\s*(true|false)', '"periodicReplication": true'
  $raw = $raw -replace '"periodicReplicationInterval":\s*\d+', '"periodicReplicationInterval": 10'
  return $raw
}
$kicked = @()
foreach ($dev in $Devices) {
  if (-not (Test-Path $adb)) { break }
  & $adb connect "$($dev.ip):5555" *> $null
  $serial = "$($dev.ip):5555"
  $ok = (& $adb -s $serial get-state 2>$null) -match 'device'
  if (-not $ok) { Write-Host ("  {0,-7} OFFLINE — will sync itself when it's back online" -f $dev.name) -ForegroundColor Yellow; continue }
  $rp = "$($dev.vault)/.obsidian/plugins/obsidian-livesync/data.json"
  & $adb -s $serial shell "am force-stop md.obsidian" 2>$null | Out-Null
  Start-Sleep -Milliseconds 600
  $raw = (& $adb -s $serial shell "cat '$rp'" 2>$null) -join "`n"
  if ($raw -match '"isConfigured":\s*true') {
    $tmp = New-TemporaryFile
    [System.IO.File]::WriteAllText($tmp, (Set-SyncFields $raw), (New-Object System.Text.UTF8Encoding($false)))
    & $adb -s $serial push $tmp $rp 2>$null | Out-Null
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
  & $adb -s $serial shell "monkey -p md.obsidian -c android.intent.category.LAUNCHER 1" 2>$null | Out-Null
  Write-Host ("  {0,-7} forced (Obsidian restarted + foregrounded; pulling)" -f $dev.name) -ForegroundColor Green
  $kicked += $dev
}

# 3. Let replication run, then verify convergence by comparing synced-file counts.
Write-Host "`nLetting replication run ${WaitSeconds}s..." -ForegroundColor Cyan
Start-Sleep -Seconds $WaitSeconds

$excl = '\\(cursor-state|rcp-enhanced-logs|sync-health|\.obsidian)\\'
$masterCount = (Get-ChildItem $VaultDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch $excl }).Count
Write-Host "`n=== Convergence (synced files) ===" -ForegroundColor Cyan
Write-Host ("  master (this laptop): {0} files" -f $masterCount)
foreach ($dev in $kicked) {
  $serial = "$($dev.ip):5555"
  $c = (& $adb -s $serial shell "find '$($dev.vault)' -type f ! -path '*/cursor-state/*' ! -path '*/rcp-enhanced-logs/*' ! -path '*/sync-health/*' ! -path '*/.obsidian/*' 2>/dev/null | wc -l").Trim()
  $pct = if ($masterCount -gt 0) { [math]::Round(100 * [int]$c / $masterCount, 0) } else { 0 }
  $col = if ([int]$c -ge $masterCount) { 'Green' } else { 'Yellow' }
  Write-Host ("  {0,-7} {1} files ({2}% of master){3}" -f $dev.name, $c, $pct, $(if ([int]$c -lt $masterCount) { ' — still pulling; keep Obsidian in foreground' } else { ' OK' })) -ForegroundColor $col
}
Write-Host "`nMobiles only sync in the foreground — if one is short, open its Obsidian and wait." -ForegroundColor DarkGray
Write-Host "Other laptops converge on their own 10s timer while their Obsidian is open." -ForegroundColor DarkGray
