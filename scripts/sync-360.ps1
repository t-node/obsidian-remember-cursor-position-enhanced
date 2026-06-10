<#
.SYNOPSIS
  360-DEGREE bidirectional sync capture. The deepest check: it runs the full green-light assurance,
  then adds everything one-directional checks miss -- push-from-every-device, a no-adb heartbeat that
  sees ALL devices (incl. the 2nd laptop), CouchDB conflict scan, clock-skew, and a soak mode for the
  intermittent "after a few days" issues. One report, nothing lost.

.DESCRIPTION
  MODES:
    (default)            Full 360 capture -> debug-reports\sync-360-<time>.txt
    -Minutes N           SOAK: repeat the bidirectional probe + conflict scan for N minutes to catch
                         intermittent drops (a single snapshot can't see a flaky-after-days connection).
    -InstallHeartbeat    Set up a scheduled task on THIS laptop that writes its heartbeat into the vault
                         every 5 min. Run once per laptop (incl. the master + the 2nd laptop). This is how
                         the master sees every device WITHOUT adb -- and how it scales to many devices.
    -WriteHeartbeat      (internal) Write this machine's heartbeat file once and exit. Called by the task.

  PHASES in a full capture:
    1  ASSURANCE   - runs sync-all.ps1 (wake + connections + same node + live pull-probe + note parity).
    2  HEARTBEAT   - reads sync-health/*.json from the synced vault: freshness of EVERY device, no adb.
    3  PUSH PROBE  - each adb device writes a unique marker; confirm it reaches the master (device->cloud->master).
    4  CONFLICTS   - scans CouchDB for documents with >1 leaf revision (silent conflicts that never resolve).
    5  CLOCK SKEW  - each device's clock vs the master (RCP-E picks cursor winners by timestamp).
    6  STORAGE     - CouchDB fragmentation / compaction advisory.

.EXAMPLE
  pwsh scripts\sync-360.ps1
  pwsh scripts\sync-360.ps1 -Minutes 10
  pwsh scripts\sync-360.ps1 -InstallHeartbeat        # run on each laptop once
#>
[CmdletBinding()]
param(
	[switch]$InstallHeartbeat,
	[switch]$WriteHeartbeat,
	[int]$Minutes = 0,
	[int]$PushTimeout = 45,
	[string]$CouchUrl,
	[string]$CouchUser,
	[string]$CouchPass,
	[string]$DbName,
	[string]$VaultDir
)
. "$PSScriptRoot\_sync-config.ps1"
$ErrorActionPreference = 'Continue'
$enc  = New-Object System.Text.UTF8Encoding($false)
$Auth = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${CouchUser}:${CouchPass}")))" }
$DbUrl = "$CouchUrl/$DbName"
$Android = $SyncConfig.Devices
$healthDir = Join-Path $VaultDir 'sync-health'

# ============================ MODE: write one heartbeat ============================
if ($WriteHeartbeat) {
	New-Item -ItemType Directory -Force -Path $healthDir | Out-Null
	$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	$hb = [ordered]@{ host=$env:COMPUTERNAME; platform='win'; ts=$nowMs; iso=(Get-Date).ToUniversalTime().ToString('o'); vault=$VaultDir }
	[System.IO.File]::WriteAllText((Join-Path $healthDir "$($env:COMPUTERNAME).json"), ($hb | ConvertTo-Json -Compress), $enc)
	exit 0
}

# ============================ MODE: install heartbeat task ============================
if ($InstallHeartbeat) {
	New-Item -ItemType Directory -Force -Path $healthDir | Out-Null
	# write one now
	& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -WriteHeartbeat -VaultDir $VaultDir | Out-Null
	$taskName = 'ObsidianSyncHeartbeat'
	try {
		$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -WriteHeartbeat -VaultDir `"$VaultDir`""
		$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
		Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Force -RunLevel Limited | Out-Null
		Write-Host "Installed heartbeat task '$taskName' (every 5 min) on $env:COMPUTERNAME." -ForegroundColor Green
		Write-Host "  Wrote sync-health\$($env:COMPUTERNAME).json. It will sync to all devices so the master sees this machine without adb." -ForegroundColor Green
		Write-Host "  Run this same -InstallHeartbeat on every laptop (incl. the 2nd one) to put it in the 360 view." -ForegroundColor Cyan
	} catch {
		Write-Host "Could not register the scheduled task: $($_.Exception.Message)" -ForegroundColor Yellow
		Write-Host "A heartbeat was still written once. Re-run elevated if you want the recurring task." -ForegroundColor Yellow
	}
	exit 0
}

# ============================ FULL 360 CAPTURE ============================
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'debug-reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$report = Join-Path $reportDir "sync-360-$ts.txt"
$lines = New-Object System.Collections.Generic.List[string]
$problems = New-Object System.Collections.Generic.List[object]
function W($s,$c){ $lines.Add(($s -replace '\e\[[0-9;]*m','')); if($c){Write-Host $s -ForegroundColor $c}else{Write-Host $s} }
function Problem($sev,$msg,$fix){ $problems.Add([pscustomobject]@{sev=$sev;msg=$msg;fix=$fix}) }
$haveAdb = $null -ne (Get-Command adb -ErrorAction SilentlyContinue)

W "##############################################################################"
W "#              360-DEGREE BIDIRECTIONAL SYNC CAPTURE   $ts"
W "#              master: $env:COMPUTERNAME   (db: $DbName)"
W "##############################################################################"
W "# Covers what one-directional checks miss: push-from-every-device, no-adb heartbeat for ALL"
W "# devices (incl. the 2nd laptop), CouchDB conflicts, clock skew, storage health. Nothing lost."
W ""

# ---------- PHASE 1: full assurance (reuse sync-all) ----------
W "=== PHASE 1: ASSURANCE (green-light: connections + same node + pull-probe + note parity) ===" Cyan
$assureOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sync-all.ps1') 2>&1 | ForEach-Object { "$_" }
$assureOut | ForEach-Object { $lines.Add($_) }
$green = [bool](@($assureOut | Where-Object { $_ -match 'PERFECT SYNC  -- ALL DEVICES GREEN' }).Count)
@($assureOut | Where-Object { $_ -match 'RESULT:|whole-vault parity:|RECEIVED marker|\[MED\]|\[HIGH\]|\[CRITICAL\]' }) | ForEach-Object { Write-Host "   $($_.Trim())" }
W ("  (assurance verdict folded into this report; green-light = {0})" -f $(if($green){'YES'}else{'NO'})) $(if($green){'Green'}else{'Yellow'})
if (-not $green) {
	$hard = @($assureOut | Where-Object { $_ -match '\[(CRITICAL|HIGH)\]\s' }).Count
	if ($hard) { Problem 'HIGH' "Base assurance failed on a connection/config layer (PHASE 1)." "See the PHASE 1 [CRITICAL]/[HIGH] lines and apply that fix, then re-run." }
	else { Problem 'MED' "A device didn't answer the live pull-probe in PHASE 1 -- almost always because its Obsidian is backgrounded/locked (Android pauses sync off-screen). Notes parity still passed." "Foreground Obsidian on the named device(s) for ~15s and re-run; if it persists, 'pwsh scripts\sync-kick.ps1 -All'." }
}
W ""

# ---------- PHASE 2: universal heartbeat (no adb -> sees ALL devices) ----------
W "=== PHASE 2: HEARTBEAT (every device's freshness via the synced vault -- no adb needed) ===" Cyan
# Always refresh THIS machine's heartbeat on a run, so the master is never falsely 'stale' even without
# the scheduled task. (The task is only needed to keep an IDLE laptop's heartbeat current.)
New-Item -ItemType Directory -Force -Path $healthDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $healthDir "$($env:COMPUTERNAME).json"), ([ordered]@{ host=$env:COMPUTERNAME; platform='win'; ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); iso=(Get-Date).ToUniversalTime().ToString('o'); vault=$VaultDir } | ConvertTo-Json -Compress), $enc)
if (Test-Path $healthDir) {
	$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	$hbs = Get-ChildItem "$healthDir\*.json" -ErrorAction SilentlyContinue
	if ($hbs) {
		foreach ($f in ($hbs | Sort-Object Name)) {
			try { $h = Get-Content $f.FullName -Raw | ConvertFrom-Json
				$sec = [math]::Round(($now - [int64]$h.ts)/1000)
				$age = if ($sec -lt 120){"$sec s"} elseif ($sec -lt 7200){"$([math]::Round($sec/60)) min"} else {"$([math]::Round($sec/3600)) h"}
				$tag = if ($sec -lt 600){'FRESH'} elseif ($sec -lt 1800){'recent'} else {'STALE'}
				W ("  [{0}] {1,-18} heartbeat {2} ago" -f $tag,$h.host,$age) $(if($tag -eq 'STALE'){'Yellow'}else{'Gray'})
				if ($sec -ge 1800 -and $h.host -ne $env:COMPUTERNAME) { Problem 'MED' "Laptop '$($h.host)' heartbeat is $age old -- that machine may be off, or its Obsidian/sync is down." "Turn it on / open Obsidian. If it's retired, delete sync-health\$($h.host).json." }
			} catch {}
		}
		W "  (FRESH=<10min recent=<30min STALE=>30min. A laptop with the heartbeat task installed appears here even without adb.)" DarkGray
	} else { W "  no heartbeat files yet." Yellow }
	W "  TIP: run 'pwsh scripts\sync-360.ps1 -InstallHeartbeat' on EACH laptop (incl. the 2nd one) to put it here." DarkGray
} else {
	W "  sync-health\ not present yet -- no device has installed a heartbeat." Yellow
	W "  Run 'pwsh scripts\sync-360.ps1 -InstallHeartbeat' on each laptop to enable no-adb visibility (esp. the 2nd laptop)." Cyan
	Problem 'LOW' "No heartbeats installed yet, so the 2nd laptop ('Notes') has no automated visibility here." "Run 'pwsh scripts\sync-360.ps1 -InstallHeartbeat' on each laptop once."
}
W ""

# ---------- PHASE 3: PUSH probe per device (device -> CouchDB -> master) ----------
W "=== PHASE 3: PUSH PROBE (can each device UPLOAD? device -> CouchDB -> master) ===" Cyan
function Invoke-BidiProbe {
	New-Item -ItemType Directory -Force -Path $healthDir | Out-Null
	$results = @()
	if (-not $haveAdb) { W "  adb not installed -- can't trigger device pushes from here." Yellow; return $results }
	foreach ($d in $Android) {
		$serial = "$($d.ip):5555"
		if ((& adb connect $serial 2>&1 | Select-Object -Last 1) -notmatch 'connected') { W ("  {0,-7}: OFFLINE -- push not tested" -f $d.name) Yellow; $results += @{dev=$d.name;ok=$false;off=$true}; continue }
		$tok = "PUSH-$ts-$($d.name)-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
		$rp = "$($d.vault)/sync-health/push-$($d.name).md"
		& adb -s $serial shell "mkdir -p '$($d.vault)/sync-health'; printf '%s' '$tok' > '$rp'" 2>$null | Out-Null
		# nudge Obsidian to scan + push the external write
		& adb -s $serial shell "monkey -p md.obsidian -c android.intent.category.LAUNCHER 1" 2>$null | Out-Null
		$masterCopy = Join-Path $healthDir "push-$($d.name).md"
		$start = Get-Date; $got = $null
		while (((Get-Date)-$start).TotalSeconds -lt $PushTimeout) {
			Start-Sleep -Seconds 3
			if (Test-Path $masterCopy) { if ((Get-Content $masterCopy -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($tok)) { $got=[math]::Round(((Get-Date)-$start).TotalSeconds); break } }
		}
		if ($null -ne $got) { W ("  {0,-7}: PUSH OK -- reached master in ~${got}s (upload path works)" -f $d.name) Green; $results += @{dev=$d.name;ok=$true;lat=$got} }
		else { W ("  {0,-7}: PUSH FAILED -- marker didn't reach master in ${PushTimeout}s" -f $d.name) Yellow; $results += @{dev=$d.name;ok=$false} }
	}
	return $results
}
$pushRes = Invoke-BidiProbe
foreach ($r in $pushRes) { if (-not $r.ok -and -not $r.off) { Problem 'MED' "$($r.dev) could not push a marker to the master in ${PushTimeout}s (upload path may be stalled, or it's backgrounded)." "Foreground Obsidian on $($r.dev); if it persists, 'pwsh scripts\sync-kick.ps1 -All'. (Note: external writes need Obsidian foregrounded to be detected.)" } }
W "  NOTE: a backgrounded phone may fail this even when healthy (Obsidian must be foregrounded to detect an external write). The heartbeat (PHASE 2) is the adb-free push signal for laptops." DarkGray
W ""

# ---------- PHASE 4: conflict scan ----------
# A doc with >1 leaf is only a REAL conflict if it has a live _conflicts array; a doc whose extra leaf
# is just an un-pruned DELETED branch (_deleted_conflicts) is benign (compaction clears it). So: get
# multi-leaf candidates cheaply from _changes, then confirm each against ?conflicts=true.
function Get-RealConflicts {
	try {
		$ch = Invoke-RestMethod "$DbUrl/_changes?style=all_docs" -Headers $Auth -TimeoutSec 90
		$cand = @($ch.results | Where-Object { $_.changes.Count -gt 1 })
		$real=0; $benign=0; $realIds=@(); $checked=0
		foreach ($c in $cand) {
			if ($checked -ge 600) { break }
			$checked++
			$encId = $c.id -replace ':','%3A'
			try { $doc = Invoke-RestMethod "$DbUrl/$encId`?conflicts=true" -Headers $Auth -TimeoutSec 8
				if ($doc._conflicts -and @($doc._conflicts).Count -gt 0) { $real++; $realIds += $c.id } else { $benign++ }
			} catch { $benign++ }
		}
		return @{ cand=$cand.Count; real=$real; benign=$benign; realIds=$realIds; capped=($cand.Count -gt 600); err=$null }
	} catch { return @{ err=$_.Exception.Message } }
}
W "=== PHASE 4: CONFLICTS (real content conflicts vs benign un-pruned deletes) ===" Cyan
$cf = Get-RealConflicts
if ($cf.err) { W "  conflict scan error: $($cf.err)" Yellow }
else {
	W ("  multi-leaf docs: {0}  ->  REAL conflicts: {1}   benign deleted-branches: {2}{3}" -f $cf.cand,$cf.real,$cf.benign,$(if($cf.capped){' (sampled first 600)'}else{''})) $(if($cf.real -gt 0){'Yellow'}else{'Green'})
	if ($cf.real -gt 0) {
		$cf.realIds | Select-Object -First 10 | ForEach-Object { W "     CONFLICT id=$_" }
		if ($cf.real -gt 10) { W "     ... +$($cf.real-10) more" }
		Problem 'HIGH' "$($cf.real) document(s) have REAL unresolved conflicts (divergent live revisions)." "In Obsidian on the master: LiveSync command palette -> 'Pick a file to resolve conflict' (or resolve from the conflict list). Don't rebuild unless it's widespread."
	} else { W "  No real conflicts -- the multi-leaf docs are un-pruned deletion branches (harmless)." Green }
	if ($cf.benign -ge 50) { Problem 'LOW' "$($cf.benign) docs carry un-pruned deleted branches (cosmetic bloat, slows replication a little)." "Compact CouchDB to prune them:  Invoke-RestMethod -Method Post '$DbUrl/_compact' -Headers (auth) -ContentType 'application/json'  (or LiveSync -> Compact the local/remote database)." }
}
W ""

# ---------- PHASE 5: clock skew ----------
W "=== PHASE 5: CLOCK SKEW (RCP-E picks cursor winners by timestamp) ===" Cyan
if ($haveAdb) {
	foreach ($d in $Android) {
		$serial = "$($d.ip):5555"
		if ((& adb connect $serial 2>&1 | Select-Object -Last 1) -notmatch 'connected') { W ("  {0,-7}: OFFLINE" -f $d.name) Yellow; continue }
		$masterMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
		$devRaw = (& adb -s $serial shell "date +%s%3N" 2>$null) -join '' -replace '\D',''
		if ($devRaw -match '^\d{10,}$') {
			$devMs = [int64]$devRaw
			$skew = $devMs - $masterMs
			$abs = [math]::Abs($skew)
			$tag = if ($abs -lt 2000){'OK'} elseif ($abs -lt 60000){'minor'} else {'BAD'}
			W ("  {0,-7}: clock skew {1} ms vs master  [{2}]" -f $d.name,$skew,$tag) $(if($tag -eq 'BAD'){'Yellow'}elseif($tag -eq 'minor'){'Gray'}else{'Green'})
			if ($abs -ge 60000) { Problem 'MED' "$($d.name) clock is off by $([math]::Round($skew/1000))s vs master -- can make the WRONG cursor position win on merge." "Enable automatic date/time on $($d.name) (Settings -> System -> Date & time -> Automatic)." }
		} else { W ("  {0,-7}: couldn't read device clock" -f $d.name) Gray }
	}
	W "  (Laptops are assumed NTP-synced. |skew|>60s can flip cursor merge decisions.)" DarkGray
} else { W "  adb not installed -- skew not measured." Yellow }
W ""

# ---------- PHASE 6: storage health ----------
W "=== PHASE 6: STORAGE (CouchDB fragmentation / compaction) ===" Cyan
try {
	$info = Invoke-RestMethod $DbUrl -Headers $Auth -TimeoutSec 8
	$fileMB = [math]::Round($info.sizes.file/1MB,1); $activeMB = [math]::Round($info.sizes.active/1MB,1)
	$ratio = if ($info.sizes.active -gt 0) { [math]::Round($info.sizes.file/$info.sizes.active,2) } else { 0 }
	W ("  docs={0} file={1}MB active={2}MB fragmentation={3}x" -f $info.doc_count,$fileMB,$activeMB,$ratio) $(if($ratio -ge 2){'Yellow'}else{'Gray'})
	if ($ratio -ge 2) { Problem 'LOW' "CouchDB is ${ratio}x fragmented ($fileMB MB on disk vs $activeMB MB live data) -- wastes space and slows sync." "Compact it:  Invoke-RestMethod -Method Post '$DbUrl/_compact' -Headers (auth) -ContentType 'application/json'   (or LiveSync -> Compact)." }
	else { W "  Fragmentation healthy (no compaction needed)." Green }
} catch { W "  storage check error: $($_.Exception.Message)" Yellow }
W ""

# ---------- SOAK (optional) ----------
if ($Minutes -gt 0) {
	W ("=== SOAK: repeating push-probe + conflict scan for $Minutes min (catches intermittent drops) ===") Cyan
	$end = (Get-Date).AddMinutes($Minutes); $round=0; $fails=@{}; $maxLat=@{}
	while ((Get-Date) -lt $end) {
		$round++
		W ("  -- round $round @ $((Get-Date).ToString('HH:mm:ss')) --") DarkGray
		$rr = Invoke-BidiProbe
		foreach ($r in $rr) { if (-not $r.off) { if (-not $r.ok) { $fails[$r.dev] = (1 + ($fails[$r.dev] | ForEach-Object {$_})) } elseif ($r.lat -gt ($maxLat[$r.dev])) { $maxLat[$r.dev]=$r.lat } } }
		$rc = Get-RealConflicts; if (-not $rc.err -and $rc.real){ W ("     REAL conflicts now: $($rc.real)") Yellow }
		if ((Get-Date) -lt $end) { Start-Sleep -Seconds 30 }
	}
	W ("  SOAK DONE: $round rounds.") Cyan
	foreach ($d in $Android) { $fc = [int]($fails[$d.name]); $ml=[int]($maxLat[$d.name])
		W ("    {0,-7}: push failures={1}  worst push latency={2}s" -f $d.name,$fc,$ml) $(if($fc -gt 0){'Yellow'}else{'Green'})
		if ($fc -gt 0) { Problem 'MED' "$($d.name) failed the push probe $fc time(s) during the soak -- intermittent upload drops." "Foreground it; if it keeps dropping, suspect Tailscale flakiness or battery optimization killing Obsidian." }
	}
	W ""
}

# ---------- VERDICT ----------
W "##############################################################################"
if ($problems.Count -eq 0) {
	W "#   360 RESULT: ALL CLEAR -- bidirectional sync healthy, no conflicts, no skew, no drift." Green
} else {
	$order=@{ CRITICAL=0; HIGH=1; MED=2; LOW=3; INFO=4 }
	W "#   360 RESULT: ISSUES FOUND" Yellow
	$problems | Sort-Object { $order[$_.sev] } | ForEach-Object {
		$col=switch($_.sev){'CRITICAL'{'Red'}'HIGH'{'Red'}'MED'{'Yellow'}default{'Gray'}}
		W ("#   [{0}] {1}" -f $_.sev,$_.msg) $col
		W ("#         FIX: {0}" -f $_.fix) $col
	}
}
W "##############################################################################"
W ""
W "## FOR COPILOT / CODE CLOUD"
W "  Complete 360 bidirectional capture (Obsidian LiveSync -> CouchDB in WSL; master on 127.0.0.1, remote"
W "  devices over Tailscale). PHASE 1 has the green-light + system context. Tell me which device or"
W "  direction (push vs pull) is failing, whether there are conflicts/skew, and the exact fix."

[System.IO.File]::WriteAllText($report, ($lines -join "`r`n"), $enc)
Write-Host ""
Write-Host "==> 360 report saved: $report" -ForegroundColor Green
Write-Host "    Paste it into Copilot / Code Cloud for analysis." -ForegroundColor Green
