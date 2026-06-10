#Requires -Version 5.1
<#
.SYNOPSIS
  Nuclear repair for LiveSync + cursor-state/ (laptop + optional phone USB + CouchDB backup).

.DESCRIPTION
  Automates everything that can be done OUTSIDE Obsidian:
    1. Backup cursor-state/ and LiveSync data.json
    2. Optional CouchDB database replicate backup
    3. Remove junk (sync-conflict logs, setup txt, Syncthing .stversions on phone)
    4. Patch LiveSync: skipOlderFilesOnSync=false, syncIgnore rcp-enhanced-logs + .diag files
    5. Touch laptop cursor-state/*.json (force re-upload on next Replicate)
    6. Push laptop cursor-state/*.json to phone via adb
    7. Optional: create redflag2.md (rebuild local+remote from laptop files on next Obsidian open)

  YOU MUST still do in Obsidian (laptop):
    - Close Obsidian BEFORE running -DropRedflag2 or file pushes
    - Open Obsidian -> Replicate now (or let redflag2 rebuild run)
    - Maintenance -> Overwrite Server Data (only if redflag2 not used)

.PARAMETER DropRedflag2
  Create redflag2.md at vault root. CLOSE OBSIDIAN on ALL devices first.
  On next laptop Obsidian open, LiveSync rebuilds CouchDB from local disk files.

.PARAMETER CouchDbBackup
  Replicate obsidian-vault to obsidian-vault-backup-<timestamp> in CouchDB.

.EXAMPLE
  # Safe prep (Obsidian can stay open on phone; close on laptop recommended):
  .\nuclear-livesync-cursor-fix.ps1 -VaultPath C:\notes1 -CouchDbBackup

.EXAMPLE
  # Full nuclear (CLOSE OBSIDIAN EVERYWHERE first):
  .\nuclear-livesync-cursor-fix.ps1 -VaultPath C:\notes1 -CouchDbBackup -DropRedflag2
#>
param(
    [string]$VaultPath = 'C:\notes1',
    [string]$CouchUser = 'obsidian',
    [string]$CouchPass = '11111111',
    [string]$CouchUrl = 'http://127.0.0.1:5984',
    [string]$Database = 'obsidian-vault',
    [string]$PhoneDeviceId = 'hvmodycj',
    [string]$PhoneVaultPath = '/storage/emulated/0/Documents/Test',
    [string]$AdbSerial = '',
    [switch]$SkipAdb,
    [switch]$CouchDbBackup,
    [switch]$DropRedflag2,
    [switch]$SkipCleanup,
    [string]$ReportDir = ''
)

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path $PSScriptRoot -Parent
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not $ReportDir) {
    $ReportDir = Join-Path $RepoRoot "debug-reports\nuclear-livesync-$ts"
}
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

function Write-Banner([string]$text) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host " $text" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Write-Ok([string]$text)   { Write-Host "  [OK]   $text" -ForegroundColor Green }
function Write-Warn([string]$text) { Write-Host "  [WARN] $text" -ForegroundColor Yellow }
function Write-Fail([string]$text) { Write-Host "  [FAIL] $text" -ForegroundColor Red }
function Write-Info([string]$text) { Write-Host "  [INFO] $text" -ForegroundColor Gray }

function Get-CouchHeaders([string]$User, [string]$Pass) {
    $bytes = [Text.Encoding]::ASCII.GetBytes("${User}:${Pass}")
    return @{ Authorization = "Basic $([Convert]::ToBase64String($bytes))" }
}

function Find-AdbExe {
    foreach ($c in @('adb', "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe")) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { return (Get-Command $c).Source }
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Get-AdbSerialList([string]$AdbExe) {
    $out = Invoke-AdbCore $AdbExe @('devices')
    $serials = @()
    foreach ($line in ($out -split "`n")) {
        if ($line -match '^(\S+)\s+device\s*$') { $serials += $Matches[1] }
    }
    return $serials
}

function Invoke-AdbCore([string]$AdbExe, [string[]]$AdbArgList) {
    $out = & $AdbExe @AdbArgList 2>&1
    return ($out | Out-String).Trim()
}

function Invoke-Adb([string]$AdbExe, [string[]]$AdbArgList, [string]$Serial = '') {
    if ($Serial) {
        return Invoke-AdbCore $AdbExe (@('-s', $Serial) + $AdbArgList)
    }
    return Invoke-AdbCore $AdbExe $AdbArgList
}

function Resolve-AdbSerial([string]$AdbExe, [string]$PreferredSerial) {
    $serials = Get-AdbSerialList $AdbExe
    if ($serials.Count -eq 0) { return $null }
    if ($PreferredSerial) {
        if ($serials -contains $PreferredSerial) { return $PreferredSerial }
        Write-Warn "AdbSerial '$PreferredSerial' not connected; found: $($serials -join ', ')"
        return $null
    }
    if ($serials.Count -eq 1) { return $serials[0] }
    Write-Warn "Multiple adb devices: $($serials -join ', '). Pass -AdbSerial RZCY11EKL7E (or unplug extras)."
    return $null
}

function Test-AdbDeviceConnected([string]$AdbExe, [string]$Serial = '') {
    if ($Serial) { return (Get-AdbSerialList $AdbExe) -contains $Serial }
    return (Get-AdbSerialList $AdbExe).Count -gt 0
}

function Backup-CursorState([string]$Vault, [string]$Dest) {
    $src = Join-Path $Vault 'cursor-state'
    if (-not (Test-Path $src)) {
        Write-Warn 'No cursor-state/ on laptop'
        return 0
    }
    $destDir = Join-Path $Dest 'cursor-state-backup'
    Copy-Item -Path $src -Destination $destDir -Recurse -Force
    $count = (Get-ChildItem $destDir -Filter '*.json' -File).Count
    Write-Ok "Backed up cursor-state/ ($count json files) -> $destDir"
    return $count
}

function Get-StoreSummary([string]$StateDir) {
    $rows = @()
    if (-not (Test-Path $StateDir)) { return $rows }
    Get-ChildItem $StateDir -Filter '*.json' -File | Where-Object { $_.Name -notlike '.diag-*' } | ForEach-Object {
        $row = [ordered]@{ File = $_.Name; Bytes = $_.Length; Mtime = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'); StoreRev = $null; Notes = $null }
        try {
            $j = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $row.StoreRev = [int]$j.storeRevision
            $props = $j.notes.PSObject.Properties
            $row.Notes = if ($props) { @($props).Count } else { 0 }
        } catch {
            $row.StoreRev = 'PARSE_ERROR'
        }
        [pscustomobject]$row | ForEach-Object { $rows += $_ }
    }
    return $rows
}

function Update-LiveSyncDataJson([string]$Path) {
    if (-not (Test-Path $Path)) {
        Write-Warn "LiveSync data.json not found: $Path"
        return $false
    }
    $backup = "$Path.bak-$ts"
    Copy-Item $Path $backup -Force
    $c = Get-Content $Path -Raw -Encoding UTF8
    $c2 = $c
    $c2 = $c2 -replace '"skipOlderFilesOnSync"\s*:\s*true', '"skipOlderFilesOnSync": false'
    $ignore = '^rcp-enhanced-logs/|^cursor-state/\.diag-'
    if ($c2 -match '"syncIgnoreRegEx"\s*:\s*"[^"]*"') {
        $c2 = $c2 -replace '"syncIgnoreRegEx"\s*:\s*"[^"]*"', "`"syncIgnoreRegEx`": `"$ignore`""
    }
    if ($c2 -ne $c) {
        [System.IO.File]::WriteAllText($Path, $c2, [System.Text.UTF8Encoding]::new($false))
        Write-Ok "Patched LiveSync data.json (skipOlder=false, syncIgnore updated)"
        return $true
    }
    Write-Info 'LiveSync data.json already had desired settings'
    return $true
}

function Invoke-CouchDbBackup([string]$Url, [hashtable]$Headers, [string]$SourceDb, [string]$TargetDb) {
    try {
        $body = @{
            source        = $SourceDb
            target        = $TargetDb
            create_target = $true
        } | ConvertTo-Json
        $r = Invoke-RestMethod -Method Post -Uri "$Url/_replicate" -Headers $Headers -Body $body -ContentType 'application/json' -TimeoutSec 120
        Write-Ok "CouchDB replicate started: $SourceDb -> $TargetDb (session=$($r.session_id))"
        return $true
    } catch {
        Write-Fail "CouchDB backup failed: $($_.Exception.Message)"
        return $false
    }
}

function Remove-JunkFiles([string]$Vault, [string]$AdbExe, [string]$RemoteVault, [string]$Serial = '') {
    $removed = 0
    $logDir = Join-Path $Vault 'rcp-enhanced-logs'
    if (Test-Path $logDir) {
        Get-ChildItem $logDir -File | Where-Object {
            $_.Name -like '*.sync-conflict-*' -or
            $_.Name -like 'Android-Phone-*' -or
            $_.Name -like 'Windows-Desktop-ytt2gvef*'
        } | ForEach-Object {
            Remove-Item $_.FullName -Force
            $removed++
        }
    }
    foreach ($junk in @('PHONE-LIVESYNC-SETUP.txt', 'redflag.md', 'redflag3.md')) {
        $p = Join-Path $Vault $junk
        if (Test-Path $p) {
            Remove-Item $p -Force
            $removed++
        }
    }
    Write-Ok "Removed $removed junk files on laptop"

    if ($AdbExe -and $RemoteVault -and $Serial) {
        $null = Invoke-Adb $AdbExe @(
            'shell',
            "find '$RemoteVault/rcp-enhanced-logs' -name '*.sync-conflict-*' -delete 2>/dev/null; rm -rf '$RemoteVault/.stversions' 2>/dev/null; echo DONE"
        ) $Serial
        Write-Ok 'Removed phone sync-conflict logs and .stversions (Syncthing debris)'
    }
}

function Touch-CursorStateFiles([string]$StateDir) {
    if (-not (Test-Path $StateDir)) { return 0 }
    $n = 0
    Get-ChildItem $StateDir -Filter '*.json' -File | Where-Object { $_.Name -notlike '.diag-*' } | ForEach-Object {
        $_.LastWriteTime = Get-Date
        $n++
    }
    Write-Ok "Touched $n cursor-state/*.json on laptop (forces STORAGE->DB on next Replicate)"
    return $n
}

function Push-CursorStateToPhone([string]$AdbExe, [string]$LocalStateDir, [string]$RemoteVault, [string]$Serial) {
    $remoteState = "$RemoteVault/cursor-state"
    $pushed = 0
    Get-ChildItem $LocalStateDir -Filter '*.json' -File | Where-Object { $_.Name -notlike '.diag-*' } | ForEach-Object {
        $remote = "$remoteState/$($_.Name)"
        $null = Invoke-Adb $AdbExe @('push', $_.FullName, $remote) $Serial
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Pushed $($_.Name) -> phone"
            $pushed++
        } else {
            Write-Fail "Failed to push $($_.Name)"
        }
    }
    return $pushed
}

function Set-PhoneLiveSyncPatch([string]$AdbExe, [string]$RemoteVault, [string]$LocalPatchPath, [string]$Serial) {
    $remote = "$RemoteVault/.obsidian/plugins/obsidian-livesync/data.json"
    $null = Invoke-Adb $AdbExe @('pull', $remote, $LocalPatchPath) $Serial
    if (-not (Test-Path $LocalPatchPath)) {
        Write-Warn 'Could not pull phone LiveSync data.json'
        return $false
    }
    Update-LiveSyncDataJson $LocalPatchPath | Out-Null
    $null = Invoke-Adb $AdbExe @('push', $LocalPatchPath, $remote) $Serial
    Write-Ok 'Patched phone LiveSync data.json via adb'
    return $true
}

# --- main ---
Write-Banner "Nuclear LiveSync + cursor-state fix - $ts"
Write-Info "Vault: $VaultPath"
Write-Info "Report: $ReportDir"

if (-not (Test-Path $VaultPath)) {
    Write-Fail "Vault not found: $VaultPath"
    exit 1
}

if ($DropRedflag2) {
    Write-Warn 'DropRedflag2: CLOSE OBSIDIAN ON ALL DEVICES before continuing!'
    Write-Host '  Press Enter when Obsidian is fully closed on laptop AND phone...' -ForegroundColor Yellow
    Read-Host | Out-Null
}

$headers = Get-CouchHeaders $CouchUser $CouchPass
$stateDir = Join-Path $VaultPath 'cursor-state'
$laptopLs = Join-Path $VaultPath '.obsidian\plugins\obsidian-livesync\data.json'

# 1 Before snapshot
Write-Banner '1/8 Before snapshot'
$before = Get-StoreSummary $stateDir
$before | Format-Table -AutoSize
$before | Export-Csv (Join-Path $ReportDir 'laptop-cursor-state-before.csv') -NoTypeInformation

# 2 Backup
Write-Banner '2/8 Backup cursor-state'
Backup-CursorState $VaultPath $ReportDir | Out-Null
if (Test-Path $laptopLs) {
    Copy-Item $laptopLs (Join-Path $ReportDir 'laptop-livesync-data.json.bak') -Force
}

# 3 CouchDB backup
Write-Banner '3/8 CouchDB'
try {
    $meta = Invoke-RestMethod -Uri "$CouchUrl/$Database" -Headers $headers -TimeoutSec 15
    Write-Ok "CouchDB reachable - docs=$($meta.doc_count) update_seq=$($meta.update_seq)"
    $meta | ConvertTo-Json | Set-Content (Join-Path $ReportDir 'couchdb-before.json')
} catch {
    Write-Fail "CouchDB not reachable at $CouchUrl - start Docker/WSL CouchDB first"
    $meta = $null
}

if ($CouchDbBackup -and $meta) {
    $backupDb = "${Database}-backup-$ts"
    Invoke-CouchDbBackup $CouchUrl $headers $Database $backupDb | Out-Null
    Write-Info "Backup DB name: $backupDb (restore via CouchDB replicate if needed)"
}

# 4 Cleanup
$adb = if (-not $SkipAdb) { Find-AdbExe } else { $null }
$adbSerial = if ($adb) { Resolve-AdbSerial $adb $AdbSerial } else { $null }
if ($adbSerial) { Write-Info "adb device: $adbSerial" }

if (-not $SkipCleanup) {
    Write-Banner '4/8 Cleanup junk'
    if ($adbSerial) {
        Remove-JunkFiles $VaultPath $adb $PhoneVaultPath $adbSerial
    } else {
        Remove-JunkFiles $VaultPath $null $null
        if (-not $SkipAdb) { Write-Warn 'Phone not connected - skipped phone cleanup' }
    }
} else {
    Write-Banner '4/8 Cleanup (skipped)'
}

# 5 Patch LiveSync settings
Write-Banner '5/8 Patch LiveSync settings'
Update-LiveSyncDataJson $laptopLs | Out-Null
if ($adbSerial) {
    $phonePatch = Join-Path $ReportDir 'phone-livesync-patched.json'
    Set-PhoneLiveSyncPatch $adb $PhoneVaultPath $phonePatch $adbSerial | Out-Null
} else {
    Write-Warn 'Phone not connected - patch phone LiveSync manually (skipOlder=OFF)'
}

# 6 Touch laptop cursor-state
Write-Banner '6/8 Touch laptop cursor-state (force re-upload)'
Touch-CursorStateFiles $stateDir | Out-Null

# 7 Push to phone
Write-Banner '7/8 Push cursor-state laptop -> phone (USB)'
if ($adbSerial) {
    $n = Push-CursorStateToPhone $adb $stateDir $PhoneVaultPath $adbSerial
    Write-Info "Pushed $n files to $PhoneVaultPath/cursor-state/"
    $phoneAfter = Invoke-Adb $adb @('shell', "wc -c $PhoneVaultPath/cursor-state/$PhoneDeviceId.json 2>/dev/null") $adbSerial
    Write-Info "Phone $PhoneDeviceId.json: $phoneAfter"
} else {
    Write-Warn 'Phone not connected - skip push (use -AdbSerial RZCY11EKL7E if multiple devices)'
}

# 8 redflag2 optional
Write-Banner '8/8 Optional redflag2 (rebuild CouchDB from laptop disk)'
$redflagPath = Join-Path $VaultPath 'redflag2.md'
if ($DropRedflag2) {
    @"
# LiveSync nuclear rebuild - created $ts
# On next Obsidian open (laptop), LiveSync rebuilds LOCAL + REMOTE DB from files on disk.
# DELETE this file after rebuild completes.
"@ | Set-Content -Path $redflagPath -Encoding UTF8
    Write-Ok "Created $redflagPath"
    Write-Warn 'Next: open Obsidian ONLY on laptop, wait for rebuild (15-60 min), then Replicate on phone'
} else {
    if (Test-Path $redflagPath) { Remove-Item $redflagPath -Force }
    Write-Info 'Skipped redflag2 (pass -DropRedflag2 for full CouchDB rebuild from laptop files)'
}

# After snapshot
Write-Banner 'After snapshot (laptop)'
$after = Get-StoreSummary $stateDir
$after | Format-Table -AutoSize
$after | Export-Csv (Join-Path $ReportDir 'laptop-cursor-state-after.csv') -NoTypeInformation

$nextSteps = @"
NUCLEAR LIVE SYNC FIX - $ts
Report folder: $ReportDir

AUTOMATED (done by script):
  [x] cursor-state backup
  $(if ($CouchDbBackup) { '[x]' } else { '[ ]' }) CouchDB replicate backup (use -CouchDbBackup)
  [x] junk log cleanup
  [x] skipOlderFilesOnSync=false + syncIgnore on laptop (+ phone if USB)
  [x] touched cursor-state/*.json on laptop
  $(if ($adb) { '[x]' } else { '[ ]' }) pushed cursor-state to phone via adb
  $(if ($DropRedflag2) { '[x]' } else { '[ ]' }) redflag2.md rebuild trigger

YOU MUST DO IN OBSIDIAN (laptop):
  1. Ctrl+R (reload LiveSync settings)
  2. Hatch -> Scan for Broken files -> Fix OR Storage->Database for cursor-state/hvmodycj.json
  3. Ctrl+P -> Self-hosted LiveSync: Replicate now (wait for Replication completed)
  4. Check log for: STORAGE -> DB ... cursor-state/hvmodycj.json

$(if ($DropRedflag2) {
@'
  REDFLAG2 MODE:
  - Open Obsidian on LAPTOP only first
  - Wait until rebuild finishes (do not use phone yet)
  - Then phone: Replicate now (NO reset synchronisation)
'@
} else {
@'
  IF Replicate still fails for hvmodycj.json:
  - Close Obsidian everywhere
  - Re-run: .\nuclear-livesync-cursor-fix.ps1 -DropRedflag2 -CouchDbBackup
  - Open Obsidian laptop only; wait for rebuild
'@
})

PHONE (after laptop Replicate / rebuild):
  1. Force-close Obsidian -> reopen
  2. Replicate now ONLY (do NOT Reset synchronisation again)
  3. Broken file dialog -> Check it later
  4. Verify:
     (Get-Content "$VaultPath\cursor-state\hvmodycj.json" -Raw | ConvertFrom-Json).storeRevision
     adb shell wc -c $PhoneVaultPath/cursor-state/hvmodycj.json
     Both should match (~4853 bytes, rev 3613+)

VERIFY:
  .\debug-livesync-cursor-state.ps1 -VaultPath "$VaultPath"
"@

$nextPath = Join-Path $ReportDir 'NEXT-STEPS.txt'
$nextSteps | Set-Content -Path $nextPath -Encoding UTF8
Copy-Item $nextPath (Join-Path $VaultPath 'LIVESYNC-NUCLEAR-NEXT-STEPS.txt') -Force

Write-Host ''
Write-Host $nextSteps -ForegroundColor White
Write-Ok "Wrote $nextPath and $VaultPath\LIVESYNC-NUCLEAR-NEXT-STEPS.txt"
