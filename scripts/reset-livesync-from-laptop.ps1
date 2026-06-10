#Requires -Version 5.1
<#
.SYNOPSIS
  One-shot reset: laptop vault is source of truth → wipe CouchDB + phone LiveSync state → rebuild.

.DESCRIPTION
  Automates everything OUTSIDE Obsidian, then one manual step on laptop:

    1. Backup cursor-state/ + LiveSync configs + CouchDB meta
    2. DELETE and recreate empty CouchDB database (= Fresh Start Wipe)
    3. Patch LiveSync settings (laptop + phone): skipOlder OFF, useHistory OFF, log ignore
    4. Force-stop Obsidian on phone + clear app data (= delete 8 GB local fetch cache)
    5. Clean junk (Syncthing debris, sync-conflict logs, old redflags)
    6. Push laptop cursor-state/*.json to phone via USB
    7. Create redflag2.md on laptop → rebuilds local+remote from disk on next laptop open
    8. Optional -WaitForRebuild: poll CouchDB, then drop redflag3.md on phone for clean fetch

  YOU MUST:
    - Close Obsidian on laptop AND phone before running
    - Open Obsidian on LAPTOP ONLY after script finishes → wait for rebuild
    - Open phone ONLY after laptop rebuild completes (script can wait and signal)

.PARAMETER WaitForRebuild
  After you open Obsidian on laptop, poll CouchDB until rebuild looks done, then
  prepare phone with redflag3.md for a small fetch.

.EXAMPLE
  # Close Obsidian everywhere, phone on USB, then:
  .\reset-livesync-from-laptop.ps1 -VaultPath C:\notes1 -AdbSerial RZCY11EKL7E

.EXAMPLE
  # Same + auto-wait for laptop rebuild (you press Enter after opening laptop Obsidian):
  .\reset-livesync-from-laptop.ps1 -WaitForRebuild -AdbSerial RZCY11EKL7E

.EXAMPLE
  # Phase 2 after laptop rebuild finished:
  .\reset-livesync-from-laptop.ps1 -PreparePhoneFetch -AdbSerial RZCY11EKL7E
#>
param(
    [string]$VaultPath = 'C:\notes1',
    [string]$CouchUser = 'obsidian',
    [string]$CouchPass,
    [string]$CouchUrl = 'http://127.0.0.1:5984',
    [string]$Database = 'obsidian-vault',
    [string]$PhoneDeviceId = 'hvmodycj',
    [string]$PhoneVaultPath = '/storage/emulated/0/Documents/Test',
    [string]$AdbSerial = 'RZCY11EKL7E',
    [string]$ObsidianAndroidPackage = 'md.obsidian',
    [switch]$SkipAdb,
    [switch]$SkipPhoneAppClear,
    [switch]$WaitForRebuild,
    [switch]$PreparePhoneFetch,
    [int]$RebuildTimeoutMinutes = 90,
    [string]$ReportDir = ''
)
. "$PSScriptRoot\_sync-config.ps1"

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path $PSScriptRoot -Parent
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not $ReportDir) {
    $ReportDir = Join-Path $RepoRoot "debug-reports\reset-livesync-$ts"
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

function Invoke-AdbCore([string]$AdbExe, [string[]]$Args) {
    $out = & $AdbExe @Args 2>&1
    return [PSCustomObject]@{ Output = ($out | Out-String).Trim(); ExitCode = $LASTEXITCODE }
}

function Invoke-Adb([string]$AdbExe, [string[]]$Args, [string]$Serial) {
    if ($Serial) { return Invoke-AdbCore $AdbExe (@('-s', $Serial) + $Args) }
    return Invoke-AdbCore $AdbExe $Args
}

function Resolve-AdbSerial([string]$AdbExe, [string]$Preferred) {
    $r = Invoke-AdbCore $AdbExe @('devices')
    $serials = @()
    foreach ($line in ($r.Output -split "`n")) {
        if ($line -match '^(\S+)\s+device\s*$') { $serials += $Matches[1] }
    }
    if ($serials.Count -eq 0) { return $null }
    if ($Preferred -and ($serials -contains $Preferred)) { return $Preferred }
    if ($serials.Count -eq 1) { return $serials[0] }
    Write-Warn "Multiple adb devices: $($serials -join ', '). Use -AdbSerial <serial>"
    return $null
}

function Get-CouchDocCount([string]$Url, [hashtable]$Headers, [string]$Db) {
    try {
        $m = Invoke-RestMethod -Uri "$Url/$Db" -Headers $Headers -TimeoutSec 15
        return [int]$m.doc_count
    } catch { return -1 }
}

function Backup-CursorState([string]$Vault, [string]$Dest) {
    $src = Join-Path $Vault 'cursor-state'
    if (-not (Test-Path $src)) { return 0 }
    $destDir = Join-Path $Dest 'cursor-state-backup'
    Copy-Item $src $destDir -Recurse -Force
    return (Get-ChildItem $destDir -Filter '*.json' -File).Count
}

function Update-LiveSyncDataJson([string]$Path) {
    if (-not (Test-Path $Path)) { return $false }
    Copy-Item $Path "$Path.bak-$ts" -Force
    $c = Get-Content $Path -Raw -Encoding UTF8
    $c2 = $c
    $c2 = $c2 -replace '"skipOlderFilesOnSync"\s*:\s*true', '"skipOlderFilesOnSync": false'
    $c2 = $c2 -replace '"useHistory"\s*:\s*true', '"useHistory": false'
    $c2 = $c2 -replace '"automaticallyDeleteMetadataOfDeletedFiles"\s*:\s*0', '"automaticallyDeleteMetadataOfDeletedFiles": 7'
    $ignore = '^rcp-enhanced-logs/|^cursor-state/\.diag-'
    if ($c2 -match '"syncIgnoreRegEx"\s*:\s*"[^"]*"') {
        $c2 = $c2 -replace '"syncIgnoreRegEx"\s*:\s*"[^"]*"', "`"syncIgnoreRegEx`": `"$ignore`""
    }
    if ($c2 -ne $c) {
        [System.IO.File]::WriteAllText($Path, $c2, [System.Text.UTF8Encoding]::new($false))
    }
    return $true
}

function Remove-Redflags([string]$Vault) {
    foreach ($name in @('redflag.md', 'redflag2.md', 'redflag3.md', 'flag_fetch.md', 'flag_rebuild.md')) {
        $p = Join-Path $Vault $name
        if (Test-Path $p) { Remove-Item $p -Force; Write-Info "Removed laptop $name" }
    }
}

function Remove-VaultJunk([string]$Vault) {
    $n = 0
    $logDir = Join-Path $Vault 'rcp-enhanced-logs'
    if (Test-Path $logDir) {
        Get-ChildItem $logDir -File | Where-Object { $_.Name -like '*.sync-conflict-*' } | ForEach-Object {
            Remove-Item $_.FullName -Force; $n++
        }
    }
    foreach ($junk in @('PHONE-LIVESYNC-SETUP.txt', 'LIVESYNC-NUCLEAR-NEXT-STEPS.txt')) {
        $p = Join-Path $Vault $junk
        if (Test-Path $p) { Remove-Item $p -Force; $n++ }
    }
    Write-Ok "Removed $n junk files on laptop"
}

function Invoke-WipeCouchDb([string]$Url, [hashtable]$Headers, [string]$Db) {
    $before = Get-CouchDocCount $Url $Headers $Db
    Write-Info "CouchDB before wipe: doc_count=$before"
    try {
        Invoke-RestMethod -Method Delete -Uri "$Url/$Db" -Headers $Headers -TimeoutSec 120 | Out-Null
        Write-Ok "Deleted database: $Db"
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 404) {
            Write-Warn "Database $Db did not exist (404)"
        } else {
            Write-Fail "Delete failed: $($_.Exception.Message)"
            return $false
        }
    }
    try {
        Invoke-RestMethod -Method Put -Uri "$Url/$Db" -Headers $Headers -TimeoutSec 30 | Out-Null
        Write-Ok "Created empty database: $Db"
    } catch {
        Write-Fail "Create failed: $($_.Exception.Message)"
        return $false
    }
    $after = Get-CouchDocCount $Url $Headers $Db
    Write-Ok "CouchDB after wipe: doc_count=$after (expect 0)"
    return ($after -eq 0)
}

function Stop-AndClearPhoneObsidian([string]$AdbExe, [string]$Serial, [string]$Package, [switch]$SkipClear) {
    $r1 = Invoke-Adb $AdbExe @('shell', 'am', 'force-stop', $Package) $Serial
    if ($r1.ExitCode -eq 0) { Write-Ok "Force-stopped $Package on phone" }
    else { Write-Fail "Force-stop failed: $($r1.Output)" }

    if ($SkipClear) {
        Write-Warn 'Skipped pm clear (-SkipPhoneAppClear)'
        return
    }

    Write-Warn 'Clearing Obsidian app data (removes ~8 GB LiveSync fetch cache on phone; vault folder untouched)'
    $r2 = Invoke-Adb $AdbExe @('shell', 'pm', 'clear', $Package) $Serial
    if ($r2.Output -match 'Success') { Write-Ok 'pm clear md.obsidian: Success (local LiveSync DB wiped)' }
    else { Write-Warn "pm clear output: $($r2.Output)" }
}

function Clear-PhoneVaultJunk([string]$AdbExe, [string]$Serial, [string]$RemoteVault) {
    $cmds = @(
        "rm -f '$RemoteVault/redflag.md' '$RemoteVault/redflag2.md' '$RemoteVault/redflag3.md' 2>/dev/null",
        "find '$RemoteVault/rcp-enhanced-logs' -name '*.sync-conflict-*' -delete 2>/dev/null",
        "rm -rf '$RemoteVault/.stversions' 2>/dev/null",
        "echo PHONE_JUNK_DONE"
    )
    $r = Invoke-Adb $AdbExe @('shell', ($cmds -join '; ')) $Serial
    if ($r.Output -match 'PHONE_JUNK_DONE') { Write-Ok 'Removed phone redflags + Syncthing debris' }
    else { Write-Warn "Phone cleanup: $($r.Output)" }
}

function Push-CursorStateToPhone([string]$AdbExe, [string]$Serial, [string]$LocalState, [string]$RemoteVault) {
    $remote = "$RemoteVault/cursor-state"
    Invoke-Adb $AdbExe @('shell', "mkdir -p '$remote'") $Serial | Out-Null
    $n = 0
    Get-ChildItem $LocalState -Filter '*.json' -File | Where-Object { $_.Name -notlike '.diag-*' } | ForEach-Object {
        $dest = "$remote/$($_.Name)"
        $r = Invoke-Adb $AdbExe @('push', $_.FullName, $dest) $Serial
        if ($r.ExitCode -eq 0) { Write-Ok "Pushed $($_.Name)"; $n++ }
        else { Write-Fail "Push $($_.Name): $($r.Output)" }
    }
    return $n
}

function Set-PhoneLiveSyncPatch([string]$AdbExe, [string]$Serial, [string]$RemoteVault, [string]$LocalPatch) {
    $remote = "$RemoteVault/.obsidian/plugins/obsidian-livesync/data.json"
    $r = Invoke-Adb $AdbExe @('pull', $remote, $LocalPatch) $Serial
    if (-not (Test-Path $LocalPatch)) {
        Write-Warn 'Phone LiveSync data.json not found (pm clear may have left vault .obsidian intact — OK if pull fails after clear)'
        return $false
    }
    Update-LiveSyncDataJson $LocalPatch | Out-Null
    Invoke-Adb $AdbExe @('push', $LocalPatch, $remote) $Serial | Out-Null
    Write-Ok 'Patched phone LiveSync data.json'
    return $true
}

function New-Redflag2([string]$Vault) {
    $p = Join-Path $Vault 'redflag2.md'
    @"
# LiveSync rebuild from laptop - $ts
# Created by reset-livesync-from-laptop.ps1
# Open Obsidian on THIS LAPTOP ONLY. LiveSync rebuilds local+remote from disk files.
# Delete this file after rebuild completes.
"@ | Set-Content -Path $p -Encoding UTF8
    Write-Ok "Created $p"
}

function New-PhoneRedflag3([string]$AdbExe, [string]$Serial, [string]$RemoteVault, [string]$TempDir) {
    $local = Join-Path $TempDir 'redflag3.md'
    @"
# Fetch clean CouchDB after laptop rebuild - $ts
# Open Obsidian on phone. LiveSync discards local DB and fetches from remote.
# Delete after fetch completes.
"@ | Set-Content -Path $local -Encoding UTF8
    $r = Invoke-Adb $AdbExe @('push', $local, "$RemoteVault/redflag3.md") $Serial
    if ($r.ExitCode -eq 0) { Write-Ok 'Dropped redflag3.md on phone (for fetch after laptop rebuild)' }
    else { Write-Fail "Could not push redflag3: $($r.Output)" }
}

function Wait-ForLaptopRebuild([string]$Url, [hashtable]$Headers, [string]$Db, [int]$TimeoutMin) {
    Write-Banner 'Waiting for laptop rebuild (CouchDB activity)'
    Write-Host ''
    Write-Host '  >>> Open Obsidian on LAPTOP ONLY now (vault notes1).' -ForegroundColor Yellow
    Write-Host '  >>> LiveSync should detect redflag2.md and rebuild.' -ForegroundColor Yellow
    Write-Host '  >>> Do NOT open Obsidian on the phone yet.' -ForegroundColor Yellow
    Write-Host ''
    Read-Host 'Press Enter after Obsidian is open on the laptop and LiveSync has started'

    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    $last = -1
    $stableSince = $null
    $minDocs = 50

    while ((Get-Date) -lt $deadline) {
        $count = Get-CouchDocCount $Url $Headers $Db
        $line = "$(Get-Date -Format 'HH:mm:ss')  CouchDB doc_count=$count"
        if ($count -ge $minDocs) {
            if ($count -eq $last) {
                if (-not $stableSince) { $stableSince = Get-Date }
                $stableSec = ((Get-Date) - $stableSince).TotalSeconds
                $line += "  (stable ${stableSec}s)"
                if ($stableSec -ge 120) {
                    Write-Host $line -ForegroundColor Green
                    Write-Ok "Rebuild looks complete (doc_count=$count, stable 2 min)"
                    return $count
                }
            } else {
                $stableSince = $null
            }
        } else {
            $stableSince = $null
        }
        Write-Host $line
        $last = $count
        Start-Sleep -Seconds 15
    }
    Write-Warn "Timeout after $TimeoutMin min (last doc_count=$last). Continue manually if rebuild still running."
    return $last
}

# ===== MAIN =====
Write-Banner "Reset LiveSync from laptop (source of truth) - $ts"
Write-Info "Vault: $VaultPath"
Write-Info "Report: $ReportDir"

if (-not (Test-Path $VaultPath)) {
    Write-Fail "Vault not found: $VaultPath"
    exit 1
}

# --- Phase 2 only: prepare phone fetch after laptop rebuild ---
if ($PreparePhoneFetch) {
    Write-Banner 'Phase 2: Prepare phone for clean fetch'
    $adb = Find-AdbExe
    $serial = if ($adb) { Resolve-AdbSerial $adb $AdbSerial } else { $null }
    if (-not $serial) { Write-Fail 'Phone not connected via adb'; exit 1 }
    $headers = Get-CouchHeaders $CouchUser $CouchPass
    $count = Get-CouchDocCount $CouchUrl $headers $Database
    Write-Info "CouchDB doc_count=$count (expect well below 32878; if 0, laptop rebuild not done yet)"
    if ($count -le 0) {
        Write-Fail 'CouchDB is empty — finish laptop redflag2 rebuild first'
        exit 1
    }
    if ($count -ge 25000) {
        Write-Warn 'CouchDB still very large — laptop rebuild may not have finished or failed'
    }
    Stop-AndClearPhoneObsidian $adb $serial $ObsidianAndroidPackage
    $stateDir = Join-Path $VaultPath 'cursor-state'
    if (Test-Path $stateDir) {
        Push-CursorStateToPhone $adb $serial $stateDir $PhoneVaultPath | Out-Null
    }
    New-PhoneRedflag3 $adb $serial $PhoneVaultPath $ReportDir
    Write-Ok 'Open Obsidian on phone now — small fetch via redflag3.md'
    Write-Warn 'Do NOT use Reset synchronisation'
    exit 0
}

Write-Warn 'CLOSE OBSIDIAN on laptop AND phone before continuing!'
Write-Host '  (Force-stop on phone is OK if already done)' -ForegroundColor Yellow
Read-Host 'Press Enter when Obsidian is closed everywhere'

$headers = Get-CouchHeaders $CouchUser $CouchPass
$stateDir = Join-Path $VaultPath 'cursor-state'
$laptopLs = Join-Path $VaultPath '.obsidian\plugins\obsidian-livesync\data.json'

# 1 Backup
Write-Banner '1/7 Backup'
$n = Backup-CursorState $VaultPath $ReportDir
Write-Ok "Backed up cursor-state/ ($n json files)"
if (Test-Path $laptopLs) {
    Copy-Item $laptopLs (Join-Path $ReportDir 'laptop-livesync-data.json') -Force
}
try {
    $meta = Invoke-RestMethod -Uri "$CouchUrl/$Database" -Headers $headers -TimeoutSec 15
    $meta | ConvertTo-Json | Set-Content (Join-Path $ReportDir 'couchdb-before-wipe.json')
    Write-Ok "CouchDB snapshot: doc_count=$($meta.doc_count)"
} catch {
    Write-Warn "CouchDB not reachable yet: $($_.Exception.Message)"
}

# 2 Wipe CouchDB
Write-Banner '2/7 Wipe CouchDB (= Fresh Start Wipe)'
if (-not (Invoke-WipeCouchDb $CouchUrl $headers $Database)) {
    Write-Fail 'CouchDB wipe failed — fix Docker/WSL CouchDB and re-run'
    exit 1
}

# 3 Clean + patch laptop
Write-Banner '3/7 Clean laptop vault + patch LiveSync'
Remove-Redflags $VaultPath
Remove-VaultJunk $VaultPath
if (Test-Path $laptopLs) {
    Update-LiveSyncDataJson $laptopLs | Out-Null
    Write-Ok 'Patched laptop LiveSync (skipOlder=OFF, useHistory=OFF, log ignore)'
}

# 4 Phone via adb
Write-Banner '4/7 Phone: stop app + clear cache + push cursor-state'
$adb = if (-not $SkipAdb) { Find-AdbExe } else { $null }
$serial = if ($adb) { Resolve-AdbSerial $adb $AdbSerial } else { $null }

if ($serial) {
    Write-Info "adb: $adb  serial: $serial"
    Stop-AndClearPhoneObsidian $adb $serial $ObsidianAndroidPackage -SkipClear:$SkipPhoneAppClear
    Clear-PhoneVaultJunk $adb $serial $PhoneVaultPath
    if (Test-Path $stateDir) {
        $pushed = Push-CursorStateToPhone $adb $serial $stateDir $PhoneVaultPath
        Write-Ok "Pushed $pushed cursor-state files to phone"
        $wc = Invoke-Adb $adb @('shell', "wc -c '$PhoneVaultPath/cursor-state/$PhoneDeviceId.json' 2>/dev/null") $serial
        Write-Info "Phone $PhoneDeviceId.json: $($wc.Output)"
    }
    $phonePatch = Join-Path $ReportDir 'phone-livesync-patched.json'
    Set-PhoneLiveSyncPatch $adb $serial $PhoneVaultPath $phonePatch | Out-Null
} else {
    Write-Warn 'Phone not connected (-SkipAdb or adb missing). Do force-stop + pm clear manually.'
}

# 5 redflag2 on laptop
Write-Banner '5/7 Create redflag2.md (laptop rebuild trigger)'
New-Redflag2 $VaultPath

# 6 Optional wait + phone redflag3
Write-Banner '6/7 Laptop rebuild'
$finalCount = -1
if ($WaitForRebuild) {
    $finalCount = Wait-ForLaptopRebuild $CouchUrl $headers $Database $RebuildTimeoutMinutes
    if ($serial -and $finalCount -gt 0) {
        Write-Banner '7/7 Prepare phone for clean fetch'
        Stop-AndClearPhoneObsidian $adb $serial $ObsidianAndroidPackage
        New-PhoneRedflag3 $adb $serial $PhoneVaultPath $ReportDir
        Write-Ok 'NOW open Obsidian on phone — small fetch from clean CouchDB'
    }
} else {
    Write-Banner '7/7 Manual steps (required)'
}

$manual = @"
RESET LIVESYNC FROM LAPTOP - $ts
Report: $ReportDir

AUTOMATED:
  [x] CouchDB wiped (was ~32878 docs / ~GB bloat → 0)
  [x] Laptop cursor-state backed up
  [x] Laptop LiveSync patched (useHistory OFF)
  [x] Phone Obsidian force-stopped + app data cleared (if USB connected)
  [x] cursor-state pushed laptop → phone
  [x] redflag2.md created on laptop

LAPTOP (do now if not using -WaitForRebuild):
  1. Open Obsidian on LAPTOP ONLY (vault C:\notes1)
  2. LiveSync detects redflag2.md → rebuilds local + remote from your ~10 MB vault
  3. Wait until log quiet (often 5–30 min for small vault)
  4. Verify CouchDB size:
     `$h = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("obsidian:YOUR_PASSWORD")) }
     (Invoke-RestMethod -Uri "http://127.0.0.1:5984/obsidian-vault" -Headers `$h).doc_count
     Expect: hundreds–low thousands, NOT 32878
  5. Delete C:\notes1\redflag2.md when done

PHONE (only AFTER laptop rebuild finished):
  1. Run phase 2:
     .\reset-livesync-from-laptop.ps1 -PreparePhoneFetch -AdbSerial $AdbSerial
  2. Open Obsidian on phone → small fetch (NOT gigabytes)
  3. Do NOT Reset synchronisation
  4. Delete redflag3.md on phone when done
  5. Verify:
     adb -s $AdbSerial shell wc -c $PhoneVaultPath/cursor-state/$PhoneDeviceId.json

RE-RUN full reset (only if needed again):
  Close Obsidian everywhere, then run without -PreparePhoneFetch

VERIFY:
  .\debug-livesync-cursor-state.ps1 -VaultPath C:\notes1 -AdbSerial $AdbSerial
"@

$manualPath = Join-Path $ReportDir 'NEXT-STEPS.txt'
$manual | Set-Content $manualPath -Encoding UTF8
Copy-Item $manualPath (Join-Path $VaultPath 'LIVESYNC-RESET-NEXT-STEPS.txt') -Force

Write-Host ''
Write-Host $manual -ForegroundColor White
Write-Ok "Wrote $manualPath"

if ($finalCount -gt 0 -and $finalCount -lt 20000) {
    Write-Ok "Success path: CouchDB doc_count=$finalCount (sanity check passed)"
} elseif ($finalCount -ge 20000) {
    Write-Warn "CouchDB still large (doc_count=$finalCount). Rebuild may still be running or redflag2 did not finish."
}
