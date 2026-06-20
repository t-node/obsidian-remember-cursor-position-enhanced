<#
.SYNOPSIS
  ONE interactive command to debug cross-device cursor-sync over MONTHS of history.

  It walks you through connecting each device (a USB cable works even with NO network /
  Tailscale completely dead), pulls that device's FULL local log history into the master
  archive, then analyzes the combined history of ALL devices, auto-fixes what's safe, and
  prints + saves a report of every issue found.

.DESCRIPTION
  Why this always works, regardless of any network issue:
    * Every device keeps its OWN logs locally, forever (daily files, never auto-deleted),
      so months of history survive on-device even if it never synced.
    * USB needs no network — a device whose sync/Tailscale is 100% dead can still hand over
      its history.
    * You connect devices ONE AT A TIME, in ANY order. Each pull MERGES into the shared
      archive on the master (pulling only that device's own authoritative folder), so nothing
      needs to be connected simultaneously, and the final analysis needs nothing connected.

  Flow:  master logs (already local)  ->  connect tablet (pull)  ->  connect phone (pull)
         ->  analyze the whole combined history  ->  auto-fix safe issues  ->  report.

.PARAMETER SinceDays  Limit the analysis to the last N days (default: ALL history).
.PARAMETER Auto       Skip the prompts; just pull every device reachable right now and
                      analyze. For automation / unattended testing.

.EXAMPLE
  pwsh -File scripts\debug-all-devices.ps1            # the guided, connect-each-device run
  pwsh -File scripts\debug-all-devices.ps1 -SinceDays 90
#>
[CmdletBinding()]
param([int]$SinceDays = 0, [switch]$Auto)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_sync-config.ps1"

$Repo        = Split-Path $PSScriptRoot -Parent
$DestRoot    = Join-Path $Repo 'debug-reports\history\pulled-health'   # NOT the synced vault — avoids LiveSync merge conflicts
$RcpDestRoot = Join-Path $Repo 'debug-reports\device-rcp-logs'
New-Item -ItemType Directory -Force -Path $DestRoot, $RcpDestRoot | Out-Null

function Resolve-Adb {
    $c = Get-Command adb -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path $p) { return $p }
    return $null
}
$Adb = Resolve-Adb
if (-not $Adb) { Write-Host "ERROR: adb not found (install Android platform-tools)." -ForegroundColor Red; exit 1 }
$Pwsh = (Get-Process -Id $PID).Path

function Get-ConnectedSerials {
    (& $Adb devices) | Select-String '\sdevice$' | ForEach-Object { (($_ -split '\s+')[0]).Trim() } | Where-Object { $_ }
}

# Pull ONE connected device's own log history into the shared archive. Returns a summary.
function Pull-DeviceLogs($serial) {
    $vault = $null
    foreach ($c in @('/storage/emulated/0/ObsidianVault','/storage/emulated/0/Documents/Test','/storage/emulated/0/Documents')) {
        if ((& $Adb -s $serial shell "test -d '$c/sync-health' && echo OK" 2>$null) -match 'OK') { $vault = $c; break }
    }
    if (-not $vault) {
        $found = (& $Adb -s $serial shell "ls -d /storage/emulated/0/*/sync-health 2>/dev/null | head -1" 2>$null)
        if ($found) { $vault = (($found -replace '/sync-health.*$','')).Trim() }
    }
    if (-not $vault) {
        foreach ($c in @('/storage/emulated/0/ObsidianVault','/storage/emulated/0/Documents/Test')) {
            if ((& $Adb -s $serial shell "test -d '$c/cursor-state' && echo OK" 2>$null) -match 'OK') { $vault = $c; break }
        }
    }
    if (-not $vault) { Write-Host "    ! no Obsidian vault found on $serial" -ForegroundColor Yellow; return $null }

    $idRaw = (& $Adb -s $serial shell "cat '$vault/.obsidian/plugins/remember-cursor-position-enhanced/.device-id.local.json'" 2>$null) -join ''
    $ownId = ([regex]::Match($idRaw,'"deviceId"\s*:\s*"([^"]+)"')).Groups[1].Value
    $model = ((& $Adb -s $serial shell "getprop ro.product.model" 2>$null) -join '').Trim()

    # Pull ONLY this device's own folder (authoritative); never its stale copies of others.
    $hbase = if ($ownId) { "$vault/sync-health/$ownId" } else { "$vault/sync-health" }
    $files = (& $Adb -s $serial shell "find '$hbase' -type f -name '*.jsonl' 2>/dev/null" 2>$null) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $n = 0
    foreach ($f in $files) {
        $rel  = $f.Substring("$vault/sync-health".Length).TrimStart('/')
        $dest = Join-Path $DestRoot ($rel -replace '/','\')
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        & $Adb -s $serial pull "$f" "$dest" 2>$null | Out-Null
        if (Test-Path $dest) { $n++ }
    }
    # Best-effort: RCP-E debug logs (local-only; usually off now).
    $rcp = (& $Adb -s $serial shell "ls $vault/rcp-enhanced-logs/*.log 2>/dev/null" 2>$null) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $r = 0
    foreach ($lf in $rcp) { $bn = ($lf -split '/')[-1]; & $Adb -s $serial pull "$lf" (Join-Path $RcpDestRoot "$ownId-$bn") 2>$null | Out-Null; if ($?) { $r++ } }

    # Logging-health signals: plugin version, heartbeat enabled?, Obsidian running?, freshest log entry.
    $verRaw = (& $Adb -s $serial shell "grep -m1 version $vault/.obsidian/plugins/remember-cursor-position-enhanced/manifest.json" 2>$null) -join ''
    $ver = ([regex]::Match($verRaw,'"version"\s*:\s*"([^"]+)"')).Groups[1].Value
    $rcpRaw = (& $Adb -s $serial shell "cat $vault/.obsidian/plugins/remember-cursor-position-enhanced/data.json" 2>$null) -join ''
    $hb = ([regex]::Match($rcpRaw,'"healthHeartbeat"\s*:\s*([a-z]+)')).Groups[1].Value
    if (-not $hb) { $hb = 'true' }   # default-on if the key isn't saved yet
    $obsRunning = -not [string]::IsNullOrWhiteSpace(((& $Adb -s $serial shell "pidof md.obsidian" 2>$null) -join ''))
    $lastEpoch = [int64]0
    if ($ownId -and (Test-Path (Join-Path $DestRoot $ownId))) {
        Get-ChildItem (Join-Path $DestRoot $ownId) -Filter *.jsonl -EA SilentlyContinue | ForEach-Object {
            $ln = Get-Content $_.FullName -Tail 1 -EA SilentlyContinue
            if ($ln) { $m = [regex]::Match($ln,'"tsEpoch":\s*(\d+)'); if ($m.Success -and [int64]$m.Groups[1].Value -gt $lastEpoch) { $lastEpoch = [int64]$m.Groups[1].Value } }
        }
    }
    return [PSCustomObject]@{ serial=$serial; model=$model; ownId=$ownId; healthFiles=$n; rcpLogs=$r; version=$ver; heartbeat=$hb; obsRunning=$obsRunning; lastEpoch=$lastEpoch }
}

# ---------------------------------------------------------------- banner
Write-Host ("=" * 72) -ForegroundColor Cyan
Write-Host "  DEBUG ALL DEVICES  -  rescue every device's log history, then analyze + fix" -ForegroundColor Cyan
Write-Host ("=" * 72) -ForegroundColor Cyan
Write-Host "  Connect devices ONE AT A TIME. USB works even with NO network / Tailscale down."
Write-Host "  Each device's full local history merges into the master archive. Order doesn't matter."
Write-Host ""
Write-Host "[*] Master laptop logs: already local (vault + 30-min monitor) - included automatically." -ForegroundColor Green
Write-Host "[*] Capturing a fresh master snapshot of the current state..." -ForegroundColor DarkGray
& $Pwsh -NoProfile -File (Join-Path $PSScriptRoot 'sync-history.ps1') 2>&1 | Out-Null

$Seen    = @{}
$SeenIds = @{}
$Pulled  = @()

function Pull-NewlyConnected {
    foreach ($s in @(Get-ConnectedSerials)) {
        if ($Seen.ContainsKey($s)) { continue }
        $Seen[$s] = $true
        $res = Pull-DeviceLogs $s
        if (-not $res) { continue }
        # Same physical device reached via two transports (USB + Wi-Fi) resolves to one ownId — pull once.
        if ($res.ownId -and $SeenIds.ContainsKey($res.ownId)) {
            Write-Host ("    (skip {0} - same device as id {1}, already pulled)" -f $res.serial, $res.ownId) -ForegroundColor DarkGray
            continue
        }
        if ($res.ownId) { $SeenIds[$res.ownId] = $true }
        Write-Host ("    + pulled {0} (serial {1}, id {2}): {3} history file(s), {4} rcp log(s)" -f `
            $(if($res.model){$res.model}else{'?'}), $res.serial, $(if($res.ownId){$res.ownId}else{'?'}), $res.healthFiles, $res.rcpLogs) -ForegroundColor Green
        $script:Pulled += $res
    }
}

if ($Auto) {
    foreach ($d in $Devices) { & $Adb connect "$($d.ip):5555" 2>&1 | Out-Null }
    Pull-NewlyConnected
    if (-not $Pulled.Count) { Write-Host "  (no devices reachable right now)" -ForegroundColor Yellow }
} else {
    $step = 1
    foreach ($d in $Devices) {
        $label = $d.name.ToUpper()
        Write-Host ""
        Write-Host (">>> [{0}/{1}] Connect your {2} now - USB cable (or make sure it's on Wi-Fi)." -f $step, $Devices.Count, $label) -ForegroundColor Cyan
        $ans = Read-Host "    Press ENTER when it's connected   (or type  S  to skip this device)"
        if ($ans -match '^[sS]') { Write-Host "    skipped $label" -ForegroundColor DarkGray; $step++; continue }
        & $Adb connect "$($d.ip):5555" 2>&1 | Out-Null
        $ok = $false
        for ($i=0; $i -lt 20; $i++) {
            if (@(Get-ConnectedSerials).Count) { $ok = $true; break }
            Write-Host "    waiting for device...  (enable USB debugging + tap 'Allow' on the device if asked)" -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
        }
        if (-not $ok) { Write-Host "    no device detected for $label - skipping (you can re-run later)" -ForegroundColor Yellow; $step++; continue }
        Pull-NewlyConnected
        $step++
    }
}

Write-Host ""
Write-Host ("Collected logs from {0} device(s) + master." -f $Pulled.Count) -ForegroundColor Green

# ---------------------------------------------------------------- logging health
Write-Host ""
Write-Host "=== LOGGING HEALTH — is everything actively capturing right now? ===" -ForegroundColor Cyan
$task = Get-ScheduledTask -TaskName 'ObsidianSyncHistory' -ErrorAction SilentlyContinue
if ($task) {
    $ti = Get-ScheduledTaskInfo -TaskName 'ObsidianSyncHistory' -ErrorAction SilentlyContinue
    $lr = if ($ti.LastRunTime -and $ti.LastRunTime.Year -gt 2000) { [int]((Get-Date) - $ti.LastRunTime).TotalMinutes } else { -1 }
    $ok = ($task.State -eq 'Ready' -and $lr -ge 0 -and $lr -le 45)
    Write-Host ("  master   : {0}  (task {1}, last run {2} min ago, result {3})" -f $(if($ok){'ACTIVE'}else{'CHECK'}), $task.State, $lr, $ti.LastTaskResult) -ForegroundColor $(if($ok){'Green'}else{'Yellow'})
} else {
    Write-Host "  master   : ! scheduled task NOT installed -> run  pwsh scripts\sync-history.ps1 -Install" -ForegroundColor Yellow
}
foreach ($res in ($Pulled | Where-Object { $_ })) {
    $name = if ($res.model) { $res.model } else { $res.serial }
    if ($res.heartbeat -ne 'true') {
        Write-Host ("  {0,-10}: ! heartbeat DISABLED (RCP-E 'Record device health' is off) -> NOT logging" -f $name) -ForegroundColor Red; continue
    }
    if ($res.lastEpoch -le 0) {
        Write-Host ("  {0,-10}: heartbeat on (v{1}) but no entries yet -> open Obsidian ~15s to seed it" -f $name, $res.version) -ForegroundColor Yellow; continue
    }
    $ageMin = [int](((Get-Date).ToUniversalTime() - [DateTimeOffset]::FromUnixTimeMilliseconds($res.lastEpoch).UtcDateTime).TotalMinutes)
    if ($ageMin -le 20) {
        Write-Host ("  {0,-10}: ACTIVE  (v{1}, heartbeat on, last entry {2} min ago)" -f $name, $res.version, $ageMin) -ForegroundColor Green
    } elseif ($res.obsRunning) {
        Write-Host ("  {0,-10}: CHECK  (Obsidian open but last entry {1} min ago >20 -> heartbeat may be stalled; reopen it)" -f $name, $ageMin) -ForegroundColor Yellow
    } else {
        Write-Host ("  {0,-10}: idle  (Obsidian closed; last entry {1} min ago - logging resumes when you open it; normal)" -f $name, $ageMin) -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------- analyze
Write-Host ""
Write-Host ("=" * 72) -ForegroundColor Cyan
Write-Host "  ANALYZING the combined history of ALL devices (no device needed now)..." -ForegroundColor Cyan
Write-Host ("=" * 72) -ForegroundColor Cyan
$hist = Join-Path $PSScriptRoot 'sync-history.ps1'
$aArgs = @('-NoProfile','-File',$hist,'-Analyze')
if ($SinceDays -gt 0) { $aArgs += @('-SinceDays', "$SinceDays") }
& $Pwsh @aArgs

# ---------------------------------------------------------------- safe auto-fix
Write-Host ""
Write-Host "=== AUTO-FIX (safe, automatic remediations) ===" -ForegroundColor Cyan
try {
    $auth = "${CouchUser}:${CouchPass}"
    $info = curl.exe -s -m 12 -u $auth "$CouchUrl/$DbName" | ConvertFrom-Json
    if ($info.db_name) {
        $reclaim = [long]$info.sizes.file - [long]$info.sizes.active
        if ($reclaim -gt 50MB -and -not $info.compact_running) {
            curl.exe -s -X POST -u $auth "$CouchUrl/$DbName/_compact" -H "Content-Type: application/json" | Out-Null
            Write-Host ("  [fixed] CouchDB compaction started - reclaiming ~{0} MB of disk overhead." -f [math]::Round($reclaim/1MB)) -ForegroundColor Green
        } elseif (($info.sizes.active/1MB) -gt 60) {
            Write-Host ("  [action] CouchDB real data is {0:n0} MB (bloated) - a deep clean (wipe + Overwrite remote) is needed; see SYNC-RUNBOOK.md." -f ($info.sizes.active/1MB)) -ForegroundColor Yellow
        } else {
            Write-Host ("  [ok] CouchDB is lean ({0:n1} MB) - nothing to reclaim." -f ($info.sizes.active/1MB)) -ForegroundColor Green
        }
    }
} catch { Write-Host "  CouchDB check skipped ($($_.Exception.Message))" -ForegroundColor DarkGray }
# Stuck conflict branches (the "files are conflicted" nag). Detect; offer the one-command fix.
& $Pwsh -NoProfile -File $hist -Conflicts
Write-Host "  Issues that need a device-side action (re-enable sync triggers, reconnect Wi-Fi/Tailscale)" -ForegroundColor Gray
Write-Host "  are listed in the VERDICT above with exact steps - they can't be auto-applied remotely." -ForegroundColor Gray

Write-Host ""
Write-Host "DONE. Full report saved under debug-reports\history\ANALYSIS-*.txt" -ForegroundColor Green
Write-Host "Tip: re-run anytime; connect whichever devices you can, in any order - it always merges." -ForegroundColor Gray
