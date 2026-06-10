#Requires -Version 5.1
<#
.SYNOPSIS
  End-to-end debug: phone cursor-state vs laptop vs CouchDB (LiveSync path).

.DESCRIPTION
  1. Snapshots laptop cursor-state/*.json (revisions, mtimes, Udaan #6 entry)
  2. Queries CouchDB update_seq (upload activity indicator)
  3. Optionally pulls phone vault files via USB (adb) and compares byte-for-byte
  4. Optional -Watch: re-sample laptop file every 5s to catch LiveSync delivery

  USB setup (Android):
    Settings → About phone → tap Build number 7× → Developer options → USB debugging ON
    Connect USB → allow debugging on phone → run: adb devices

.EXAMPLE
  .\debug-livesync-cursor-state.ps1

.EXAMPLE
  .\debug-livesync-cursor-state.ps1 -Watch -WatchSeconds 120

.EXAMPLE
  .\debug-livesync-cursor-state.ps1 -PhoneVaultPath "/storage/emulated/0/Documents/notes1"
#>
param(
    [string]$VaultPath = 'C:\notes1',
    [string]$CouchUser = 'obsidian',
    [string]$CouchPass,
    [string]$CouchUrl = 'http://127.0.0.1:5984',
    [string]$Database = 'obsidian-vault',
    [string]$PhoneDeviceId = 'hvmodycj',
    [string]$UdaanNoteHash = '1aym95puxyc95e',
    [string]$PhoneVaultPath = '',
    [switch]$SkipAdb,
    [switch]$Watch,
    [int]$WatchSeconds = 90,
    [string]$ReportDir = ''
)
. "$PSScriptRoot\_sync-config.ps1"

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path $PSScriptRoot -Parent

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

function Get-CouchBasicAuthHeader([string]$User, [string]$Pass) {
    $pair = "${User}:${Pass}"
    $bytes = [Text.Encoding]::ASCII.GetBytes($pair)
    return @{ Authorization = "Basic $([Convert]::ToBase64String($bytes))" }
}

function Get-DeviceStoreSnapshot([string]$StateDir) {
    $rows = @()
    if (-not (Test-Path $StateDir)) { return $rows }
    Get-ChildItem -Path $StateDir -Filter '*.json' -File | Where-Object { $_.Name -notlike '.diag-*' } | ForEach-Object {
        $row = [ordered]@{
            File       = $_.Name
            DeviceId   = $_.BaseName
            Bytes      = $_.Length
            Mtime      = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            StoreRev   = $null
            NoteCount  = $null
            Udaan6Line = $null
            Udaan6Scroll = $null
            HasUdaan6  = $false
            ParseError = $null
        }
        try {
            $j = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $row.StoreRev = [int]$j.storeRevision
            $props = $j.notes.PSObject.Properties
            $row.NoteCount = if ($props) { @($props).Count } else { 0 }
            $note = $j.notes.$UdaanNoteHash
            if ($note) {
                $row.HasUdaan6 = $true
                $row.Udaan6Line = [int]$note.cursor.from.line
                $row.Udaan6Scroll = [double]$note.scroll
            }
        } catch {
            $row.ParseError = $_.Exception.Message
        }
        [pscustomobject]$row | ForEach-Object { $rows += $_ }
    }
    return $rows
}

function Get-CouchDbMeta([string]$Url, [hashtable]$Headers, [string]$Db) {
    try {
        $r = Invoke-RestMethod -Uri "$Url/$Db" -Headers $Headers -TimeoutSec 10
        return [pscustomobject]@{
            Ok = $true
            DocCount = $r.doc_count
            UpdateSeq = $r.update_seq
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Find-AdbExe {
    $candidates = @(
        'adb',
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe",
        "${env:ProgramFiles}\Android\Android Studio\platform-tools\adb.exe"
    )
    foreach ($c in $candidates) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { return (Get-Command $c).Source }
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Invoke-Adb([string]$AdbExe, [string[]]$AdbArgList) {
    $out = & $AdbExe @AdbArgList 2>&1
    return ($out | Out-String).Trim()
}

function Test-AdbDeviceConnected([string]$AdbExe) {
    $out = Invoke-Adb $AdbExe @('devices')
    foreach ($line in ($out -split "`n")) {
        if ($line -match '^\S+\s+device\s*$') { return $true }
    }
    return $false
}

function Find-PhoneVaultPath([string]$AdbExe, [string]$Hint) {
    # Try known paths first (fast; find can fail when phone is locked or busy)
    $candidates = @(
        "/storage/emulated/0/Documents/Test",
        "/storage/emulated/0/Documents/$Hint",
        "/storage/emulated/0/Obsidian/$Hint",
        "/storage/emulated/0/Download/$Hint",
        "/storage/emulated/0/$Hint"
    )
    foreach ($p in $candidates) {
        $test = Invoke-Adb $AdbExe @('shell', "test -f '$p/cursor-state/$PhoneDeviceId.json' && echo YES || echo NO")
        if ($test -match 'YES') {
            Write-Ok "Found phone vault: $p"
            return $p
        }
    }

    Write-Info "Searching phone for cursor-state/$PhoneDeviceId.json ..."
    $find = Invoke-Adb $AdbExe @(
        'shell',
        "find /storage/emulated/0/Documents /storage/emulated/0/Obsidian -name '$PhoneDeviceId.json' 2>/dev/null | head -3"
    )
    if ($find) {
        foreach ($line in ($find -split "[\r\n]+")) {
            $file = $line.Trim()
            if ($file -match '/cursor-state/[^/]+\.json$') {
                $vault = $file -replace '/cursor-state/[^/]+\.json$', ''
                Write-Ok "Found via adb find: $vault"
                return $vault
            }
        }
    }
    return $null
}

function Pull-PhoneCursorState([string]$AdbExe, [string]$RemoteVault, [string]$DestDir) {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $pulled = @()

    foreach ($sub in @('cursor-state', 'rcp-enhanced-logs')) {
        $remote = "$RemoteVault/$sub"
        $local = Join-Path $DestDir $sub
        if (Test-Path $local) { Remove-Item -Recurse -Force $local }
        New-Item -ItemType Directory -Force -Path $local | Out-Null
        $null = Invoke-Adb $AdbExe @('pull', $remote, $local)
        if ($LASTEXITCODE -eq 0 -and (Test-Path $local)) { $pulled += $sub }
    }
    return $pulled
}

function Resolve-PulledSubDir([string]$BaseDir, [string]$SubName) {
    $direct = Join-Path $BaseDir $SubName
    if (Test-Path $direct) { return $direct }
    $nested = Join-Path $direct $SubName
    if (Test-Path $nested) { return $nested }
    return $direct
}

function Find-PulledFile([string]$PullDest, [string]$SubName, [string]$FileName) {
    $root = Join-Path $PullDest $SubName
    if (Test-Path (Join-Path $root $FileName)) { return Join-Path $root $FileName }
    $nested = Join-Path $root $SubName
    if (Test-Path (Join-Path $nested $FileName)) { return Join-Path $nested $FileName }
    $hit = Get-ChildItem -Path $PullDest -Recurse -Filter $FileName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return Join-Path $root $FileName
}

function Compare-PhoneVsLaptop([string]$PhoneFile, [string]$LaptopFile) {
    if (-not (Test-Path $PhoneFile)) { return [pscustomobject]@{ Same = $false; Reason = 'Phone file missing after pull' } }
    if (-not (Test-Path $LaptopFile)) { return [pscustomobject]@{ Same = $false; Reason = 'Laptop file missing' } }

    $ph = Get-Item $PhoneFile
    $lp = Get-Item $LaptopFile
    $phHash = (Get-FileHash -LiteralPath $PhoneFile -Algorithm SHA256).Hash
    $lpHash = (Get-FileHash -LiteralPath $LaptopFile -Algorithm SHA256).Hash

    $phJson = Get-Content -LiteralPath $PhoneFile -Raw | ConvertFrom-Json
    $lpJson = Get-Content -LiteralPath $LaptopFile -Raw | ConvertFrom-Json

    return [pscustomobject]@{
        Same          = ($phHash -eq $lpHash)
        PhoneBytes    = $ph.Length
        LaptopBytes   = $lp.Length
        PhoneMtime    = $ph.LastWriteTime
        LaptopMtime   = $lp.LastWriteTime
        PhoneStoreRev = [int]$phJson.storeRevision
        LaptopStoreRev = [int]$lpJson.storeRevision
        PhoneHash     = $phHash.Substring(0, 16)
        LaptopHash    = $lpHash.Substring(0, 16)
        PhoneHasUdaan6 = [bool]$phJson.notes.$UdaanNoteHash
        LaptopHasUdaan6 = [bool]$lpJson.notes.$UdaanNoteHash
    }
}

function Write-Verdict(
    $LaptopSnap,
    $PhoneSnap,
    $Compare,
    $CouchOk,
    [string]$PhoneConnected
) {
    Write-Banner 'VERDICT'

    $phoneRow = $LaptopSnap | Where-Object { $_.DeviceId -eq $PhoneDeviceId } | Select-Object -First 1
    $laptopOwn = $LaptopSnap | Where-Object { $_.DeviceId -eq 'vyovb870' } | Select-Object -First 1

    if ($PhoneConnected -eq 'yes' -and $Compare) {
            if ($Compare.PhoneStoreRev -gt $Compare.LaptopStoreRev) {
            Write-Fail "Phone has NEWER state (rev $($Compare.PhoneStoreRev)) than laptop (rev $($Compare.LaptopStoreRev)) - LiveSync download is BROKEN."
            Write-Info "Phone file: $($Compare.PhoneBytes) bytes | Laptop file: $($Compare.LaptopBytes) bytes"
        } elseif ($Compare.Same) {
            Write-Ok "Phone and laptop files are identical - sync is working for this file right now."
        } elseif ($Compare.PhoneStoreRev -lt $Compare.LaptopStoreRev) {
            Write-Warn "Laptop copy is newer than phone (unexpected for phone-only edits)."
        }

        if ($Compare.PhoneHasUdaan6 -and -not $Compare.LaptopHasUdaan6) {
            Write-Fail "Phone HAS Udaan note saved; laptop copy does NOT - confirms LiveSync not delivering hvmodycj.json."
        }
        if ($Compare.PhoneHasUdaan6) {
            Write-Info "Phone Udaan note present in pulled file."
        } else {
            Write-Warn "Phone pulled file also lacks Udaan note - problem may be phone RCP-E save, not LiveSync."
        }
    } elseif ($phoneRow) {
        $frozen = $phoneRow.Mtime -lt (Get-Date).AddHours(-1)
        if ($frozen -and $laptopOwn -and ($laptopOwn.Mtime -gt $phoneRow.Mtime)) {
            Write-Fail "Laptop phone-store file (${PhoneDeviceId}.json) frozen since $($phoneRow.Mtime) while laptop own file updates - LiveSync not delivering remote device stores."
        }
        if (-not $phoneRow.HasUdaan6) {
            Write-Warn "Laptop copy of ${PhoneDeviceId}.json has no Udaan note entry (rev $($phoneRow.StoreRev))."
        }
    }

    if (-not $CouchOk) {
        Write-Fail "CouchDB not reachable - phone cannot sync through hub."
    }

    Write-Host ''
    Write-Host 'Next actions:' -ForegroundColor White
    if ($PhoneConnected -ne 'yes') {
        Write-Host '  1. Connect phone USB + enable USB debugging, then re-run this script for phone vs laptop compare'
    }
    Write-Host '  2. On phone: open Udaan #6, scroll Q6, tap text, switch note, wait 60s with Obsidian open'
    Write-Host '  3. Re-run: .\debug-livesync-cursor-state.ps1 -Watch -WatchSeconds 120'
    Write-Host '  4. If phone rev > laptop rev: fix LiveSync on phone (Tailscale URL, Syncthing off, force sync)'
    Write-Host ''
}

# --- main ---
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $ReportDir) {
    $ReportDir = Join-Path $RepoRoot "debug-reports\livesync-cursor-$ts"
}
New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

Write-Banner "LiveSync cursor-state debug - $ts"
Write-Info "Vault: $VaultPath"
Write-Info "Report: $ReportDir"

$stateDir = Join-Path $VaultPath 'cursor-state'
$headers = Get-CouchBasicAuthHeader $CouchUser $CouchPass

# --- 1 Laptop snapshot ---
Write-Banner '1/5 Laptop cursor-state snapshot'
$laptopSnap = Get-DeviceStoreSnapshot $stateDir
$laptopSnap | Format-Table -AutoSize
$laptopSnap | Export-Csv -Path (Join-Path $ReportDir 'laptop-cursor-state.csv') -NoTypeInformation

$phoneOnLaptop = $laptopSnap | Where-Object { $_.DeviceId -eq $PhoneDeviceId } | Select-Object -First 1
if ($phoneOnLaptop) {
    Write-Info "$PhoneDeviceId.json on laptop: rev=$($phoneOnLaptop.StoreRev) bytes=$($phoneOnLaptop.Bytes) mtime=$($phoneOnLaptop.Mtime) udaan6=$($phoneOnLaptop.HasUdaan6)"
}

# --- 2 CouchDB ---
Write-Banner '2/5 CouchDB hub'
$couchBefore = Get-CouchDbMeta $CouchUrl $headers $Database
if ($couchBefore.Ok) {
    Write-Ok "CouchDB OK - docs=$($couchBefore.DocCount) update_seq=$($couchBefore.UpdateSeq)"
} else {
    Write-Fail "CouchDB: $($couchBefore.Error)"
}

# --- 3 LiveSync settings hint ---
Write-Banner '3/5 LiveSync settings (laptop data.json)'
$lsData = Join-Path $VaultPath '.obsidian\plugins\obsidian-livesync\data.json'
if (Test-Path $lsData) {
    $ls = Get-Content $lsData -Raw | ConvertFrom-Json
    Write-Info "isConfigured=$($ls.isConfigured) skipOlderFilesOnSync=$($ls.skipOlderFilesOnSync) syncIgnoreRegEx='$($ls.syncIgnoreRegEx)'"
    Write-Info "liveSync flag in file=$($ls.liveSync) (encrypted remote may still be active via activeConfigurationId)"
} else {
    Write-Warn 'LiveSync data.json not found on laptop'
}

$syncthingOnLaptop = Get-ChildItem -Path $VaultPath -Recurse -Filter '.syncthing*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($syncthingOnLaptop) {
    Write-Fail 'Syncthing temp files found in laptop vault - pause Syncthing on ALL devices for this vault'
}

# --- 4 ADB phone pull ---
Write-Banner '4/5 Phone via USB (adb)'
$adb = Find-AdbExe
$phoneConnected = 'no'
$compare = $null
$phoneSnap = $null

if ($SkipAdb) {
    Write-Info 'Skipped (-SkipAdb)'
} elseif (-not $adb) {
    Write-Warn 'adb not found - install Android platform-tools or skip with -SkipAdb'
} else {
    Write-Info "adb: $adb"
    $devices = Invoke-Adb $adb @('devices')
    Write-Info $devices

    if (Test-AdbDeviceConnected $adb) {
        $phoneConnected = 'yes'
        Write-Ok 'Phone connected'

        $remoteVault = $PhoneVaultPath
        if (-not $remoteVault) {
            $vaultFolder = Split-Path $VaultPath -Leaf
            $remoteVault = Find-PhoneVaultPath $adb $vaultFolder
        }
        if (-not $remoteVault) {
            Write-Fail "Could not find vault on phone. Pass -PhoneVaultPath '/storage/emulated/0/Documents/notes1'"
        } else {
            Write-Ok "Phone vault: $remoteVault"
            $pullDest = Join-Path $ReportDir 'phone-pull'
            $pulled = Pull-PhoneCursorState $adb $remoteVault $pullDest
            Write-Info "Pulled: $($pulled -join ', ')"

            $phoneStateDir = Resolve-PulledSubDir $pullDest 'cursor-state'
            $phoneSnap = Get-DeviceStoreSnapshot $phoneStateDir
            if ($phoneSnap) {
                Write-Host ''
                Write-Host 'Phone cursor-state (pulled):' -ForegroundColor White
                $phoneSnap | Format-Table -AutoSize
                $phoneSnap | Export-Csv -Path (Join-Path $ReportDir 'phone-cursor-state.csv') -NoTypeInformation
            }

            $phoneFile = Find-PulledFile $pullDest 'cursor-state' "${PhoneDeviceId}.json"
            $laptopFile = Join-Path $stateDir "${PhoneDeviceId}.json"
            $compare = Compare-PhoneVsLaptop $phoneFile $laptopFile
            Write-Host ''
            Write-Host 'Phone vs laptop file compare:' -ForegroundColor White
            $compare | Format-List

            # Pull latest phone RCP log tail
            $logDir = Resolve-PulledSubDir $pullDest 'rcp-enhanced-logs'
            if (Test-Path $logDir) {
                $phoneLog = Get-ChildItem $logDir -Filter "*$PhoneDeviceId*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($phoneLog) {
                    $tail = Get-Content -LiteralPath $phoneLog.FullName -Tail 40 -ErrorAction SilentlyContinue
                    $tailPath = Join-Path $ReportDir 'phone-rcp-log-tail.txt'
                    $tail | Set-Content -Path $tailPath -Encoding UTF8
                    Write-Ok "Phone RCP log tail saved: $tailPath ($($phoneLog.Name))"
                } else {
                    Write-Warn "No phone log matching *$PhoneDeviceId*.log in pull"
                }
            }
        }
    } else {
        Write-Warn 'No phone detected. Enable USB debugging and authorize this PC.'
        Write-Info 'Then run: adb devices'
    }
}

# --- 5 Watch mode ---
if ($Watch) {
    Write-Banner "5/5 Watch laptop $PhoneDeviceId.json ($WatchSeconds s)"
    Write-Info 'NOW: on phone save Udaan #6 position, keep Obsidian open 60s...'
    $target = Join-Path $stateDir "$PhoneDeviceId.json"
    $couchSeqStart = if ($couchBefore.Ok) { $couchBefore.UpdateSeq } else { $null }
    $deadline = (Get-Date).AddSeconds($WatchSeconds)
    $initialRev = $null
    if (Test-Path $target) {
        try { $initialRev = (Get-Content $target -Raw | ConvertFrom-Json).storeRevision } catch {}
    }
    while ((Get-Date) -lt $deadline) {
        $couchNow = Get-CouchDbMeta $CouchUrl $headers $Database
        $line = "$(Get-Date -Format 'HH:mm:ss')"
        if (Test-Path $target) {
            $fi = Get-Item $target
            try {
                $rev = (Get-Content $target -Raw | ConvertFrom-Json).storeRevision
                $line += " | $PhoneDeviceId rev=$rev bytes=$($fi.Length) mtime=$($fi.LastWriteTime.ToString('HH:mm:ss'))"
            } catch {
                $line += " | parse error"
            }
        } else {
            $line += " | file missing"
        }
        if ($couchNow.Ok) {
            $line += " | couch_seq=$($couchNow.UpdateSeq)"
        }
        Write-Host $line
        Start-Sleep -Seconds 5
    }
    $couchAfter = Get-CouchDbMeta $CouchUrl $headers $Database
    if ($couchBefore.Ok -and $couchAfter.Ok -and ($couchAfter.UpdateSeq -ne $couchSeqStart)) {
        Write-Ok "CouchDB activity during watch (seq $couchSeqStart -> $($couchAfter.UpdateSeq))"
    } else {
        Write-Warn 'No CouchDB seq change during watch - phone may not be uploading'
    }
    if (Test-Path $target) {
        $finalRev = (Get-Content $target -Raw | ConvertFrom-Json).storeRevision
        if ($initialRev -ne $null -and $finalRev -ne $initialRev) {
            Write-Ok "Laptop ${PhoneDeviceId}.json updated: rev $initialRev -> $finalRev"
        } else {
            Write-Fail "Laptop ${PhoneDeviceId}.json UNCHANGED during watch (still rev $finalRev)"
        }
    }
} else {
    Write-Banner '5/5 Watch (skipped)'
    Write-Info 'Run with -Watch -WatchSeconds 120 while saving on phone'
}

Write-Verdict $laptopSnap $phoneSnap $compare $couchBefore.Ok $phoneConnected

$summary = @{
    timestamp = $ts
    vaultPath = $VaultPath
    phoneConnected = $phoneConnected
    laptopSnapshot = $laptopSnap
    phoneSnapshot = $phoneSnap
    compare = $compare
    couchdb = $couchBefore
} | ConvertTo-Json -Depth 6
$summary | Set-Content -Path (Join-Path $ReportDir 'summary.json') -Encoding UTF8
Write-Info "Full report: $ReportDir"
