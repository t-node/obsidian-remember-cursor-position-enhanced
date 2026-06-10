<#
.SYNOPSIS
  ONE SCRIPT. Run it whenever sync "feels off". It tests connections, files, live syncing, and
  whether every device is up to date -- then writes ONE self-contained report you can paste
  straight into Copilot / Code Cloud and ask "what's wrong and how do I fix it?".

.DESCRIPTION
  Unlike a passive snapshot, this runs an ACTIVE end-to-end probe: it writes a unique marker into
  a note on the master, then watches that marker actually travel through CouchDB to every reachable
  device, timing each hop. That is the real test of "is it syncing right now".

  Sections in the report:
    0  SYSTEM         - plain-English description of the setup, so the AI reading it has full context.
    1  CONNECTIONS    - local CouchDB, Tailscale Serve, adb reachability of each phone/tablet.
    2  NODES          - every device CouchDB has seen, freshest-per-vault, ghosts flagged.
    3  CONFIG         - reliable-mode check per reachable device (catches drift).
    4  FILE STATE     - md5 of every cursor file across devices (who is identical / who lags NOW).
    5  LIVE PROBE     - active: marker master -> CouchDB -> each device, with per-hop latency.
    6  LOGS           - tail of RCP-E logs + recent sync decisions.
    VERDICT           - ranked problems + the single command to run.

  Changes nothing except a single throwaway note 'sync-probe.md' in the master vault (reused each run).

.PARAMETER ProbeTimeout  Seconds to wait for the marker to reach devices (default 45).
.PARAMETER NoProbe       Skip the active probe (passive checks only, faster).

.EXAMPLE
  pwsh scripts\sync-checkup.ps1
  # then open the printed report file and paste its contents into Copilot.
#>
[CmdletBinding()]
param(
	[int]$ProbeTimeout = 45,
	[switch]$NoProbe,
	[string]$CouchUrl     = 'http://127.0.0.1:5984',
	[string]$TailscaleUrl,
	[string]$CouchUser,
	[string]$CouchPass,
	[string]$DbName,
	[string]$VaultDir
)
. "$PSScriptRoot\_sync-config.ps1"
$ErrorActionPreference = 'Continue'
$DbUrl   = "$CouchUrl/$DbName"
$TsDbUrl = "$TailscaleUrl/$DbName"
$Auth = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${CouchUser}:${CouchPass}")))" }
$enc  = New-Object System.Text.UTF8Encoding($false)

$KnownVaults = @('notes1','Test','ObsidianVault','Notes')
$Android = $SyncConfig.Devices

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'debug-reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$report = Join-Path $reportDir "sync-checkup-$ts.txt"
$lines = New-Object System.Collections.Generic.List[string]
$problems = New-Object System.Collections.Generic.List[object]
function W($s,$c){ $lines.Add(($s -replace '\e\[[0-9;]*m','')); if($c){Write-Host $s -ForegroundColor $c}else{Write-Host $s} }
function Problem($sev,$msg,$fix){ $problems.Add([pscustomobject]@{sev=$sev;msg=$msg;fix=$fix}) }
$haveAdb = $null -ne (Get-Command adb -ErrorAction SilentlyContinue)

# ============================ 0  SYSTEM (context for the AI) ============================
W "##############################################################################"
W "# OBSIDIAN CURSOR-SYNC CHECKUP   $ts   (machine: $env:COMPUTERNAME)"
W "##############################################################################"
W ""
W "## 0  SYSTEM (read this first if you are an AI analyzing this report)"
W "  - Goal: one reading position synced across ~4 devices (master laptop, phone, tablet, 2nd laptop)."
W "  - A plugin (RCP-E) writes each device's scroll position to  cursor-state/<deviceId>.json  in the vault."
W "  - Those files sync via Obsidian 'Self-hosted LiveSync' -> CouchDB (db '$DbName') running in WSL on the"
W "    master. Remote devices reach CouchDB over Tailscale Serve ($TailscaleUrl). The master itself"
W "    connects locally at $CouchUrl (no Tailscale hop) -- that path is the most reliable."
W "  - RELIABLE MODE (what every device SHOULD be in): liveSync=false, periodicReplication=true,"
W "    interval<=10s, syncOnSave=true, syncOnFileOpen=true. (liveSync=true is AVOIDED: the live socket"
W "    stalls over Tailscale and, while on, suppresses the periodic fallback -> the recurring freeze.)"
W "  - HEALTHY looks like: CouchDB UP, Tailscale UP, all configs reliable, all cursor md5 identical,"
W "    the LIVE PROBE reaches every foregrounded device within ~10s, and update_seq moves during the probe."
W "  - IMPORTANT quirk: Android only syncs while Obsidian is in the FOREGROUND. A backgrounded phone"
W "    legitimately lags and is NOT a real fault. 'last_connected' in CouchDB only updates on real data"
W "    exchange, so an idle-but-healthy device can look minutes-stale -- trust md5 + the probe, not freshness."
W ""

# ============================ 1  CONNECTIONS ============================
W "## 1  CONNECTIONS"
$couchUp=$false; $seq0=$null
try {
	$db = Invoke-RestMethod $DbUrl -Headers $Auth -TimeoutSec 8
	$couchUp=$true; $seq0=[int](($db.update_seq -split '-')[0])
	W ("  CouchDB local ($CouchUrl): UP   docs={0} size={1}MB update_seq={2}" -f $db.doc_count,[math]::Round($db.sizes.active/1MB,1),$seq0) Green
} catch {
	W "  CouchDB local ($CouchUrl): DOWN -- $($_.Exception.Message)" Red
	Problem 'CRITICAL' "CouchDB unreachable at $DbUrl -- the sync hub is down, nothing can sync." "Start WSL + CouchDB (e.g. 'wsl' then 'sudo service couchdb start'). If WSL localhost forwarding dropped: 'wsl --shutdown' then restart. Re-run."
}
if ($couchUp) {
	try { $null = Invoke-RestMethod $TsDbUrl -Headers $Auth -TimeoutSec 12
		W "  Tailscale Serve ($TailscaleUrl): UP   (remote devices can reach CouchDB)" Green
	} catch {
		W "  Tailscale Serve ($TailscaleUrl): DOWN -- $($_.Exception.Message)" Red
		Problem 'HIGH' "Remote devices cannot reach CouchDB over Tailscale. Master is fine (local) but phone/tablet/2nd-laptop are cut off." "On master: confirm Tailscale Connected, then 'tailscale serve --bg --https=443 127.0.0.1:5984'."
	}
}
$adbState=@{}
if ($haveAdb) {
	foreach ($d in $Android) {
		$serial="$($d.ip):5555"; $r=(& adb connect $serial 2>&1 | Select-Object -Last 1)
		$running = if ($r -match 'connected') { (& adb -s $serial shell "pidof md.obsidian" 2>$null) } else { $null }
		$adbState[$d.name]=@{ serial=$serial; up=($r -match 'connected'); obsidian=[bool]$running }
		if ($r -match 'connected') { W ("  adb {0,-7}: connected ({1})  Obsidian {2}" -f $d.name,$serial,$(if($running){'RUNNING'}else{'not running -> it will not sync until opened'})) $(if($running){'Green'}else{'Yellow'}) }
		else { W ("  adb {0,-7}: OFFLINE ({1}) -- {2}" -f $d.name,$serial,$r) Yellow }
	}
} else { W "  adb: not installed here -- phone/tablet cannot be probed from this machine." DarkGray }
W ""

# ============================ 2  NODES ============================
if ($couchUp) {
	W "## 2  NODES (devices CouchDB has seen; freshest per vault is the real one)"
	try {
		$now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
		$mile=Invoke-RestMethod "$DbUrl/_local%2Fobsydian_livesync_milestone" -Headers $Auth -TimeoutSec 8
		$mile.node_info.PSObject.Properties | Sort-Object { $_.Value.last_connected } -Descending | ForEach-Object {
			$sec=[math]::Round(($now-$_.Value.last_connected)/1000)
			$tag=if($sec -lt 90){'ACTIVE'}elseif($sec -lt 600){'recent'}else{'STALE '}
			$age=if($sec -lt 120){"$sec s"}else{"$([math]::Round($sec/60)) min"}
			W ("  [{0}] {1,-12} vault='{2}'  {3} ago" -f $tag,$_.Name,$_.Value.vault_name,$age)
		}
		$seen=@($mile.node_info.PSObject.Properties.Value.vault_name | Sort-Object -Unique)
		$missing=$KnownVaults | Where-Object { $_ -notin $seen }
		if ($missing) { W "  !! NEVER-SEEN vaults (never connected): $($missing -join ', ')" Red
			Problem 'HIGH' "Never synced: $($missing -join ', '). LiveSync not configured/connected on that device." "Run 'pwsh scripts\fix-this-laptop.ps1' on that laptop, or finish the LiveSync wizard on mobile." }
		$byVault=$mile.node_info.PSObject.Properties | Group-Object { $_.Value.vault_name }
		$ghosts=@()
		foreach ($g in $byVault) {
			$ordered=$g.Group | Sort-Object { $_.Value.last_connected } -Descending
			$ghosts += $ordered | Select-Object -Skip 1
			$sec=[math]::Round(($now-$ordered[0].Value.last_connected)/1000)
			if ($g.Name -eq 'notes1') { continue }
			if ($sec -ge 3600 -and $g.Name -in $KnownVaults) {
				Problem 'LOW' "Device '$($g.Name)' hasn't exchanged data in $([math]::Round($sec/60)) min -- likely idle/closed (only a problem if you expect it live)." "Mobile: foreground Obsidian. Laptop: reload or 'pwsh scripts\sync-kick.ps1 -All'." }
		}
		if ($ghosts.Count) { W ("  (ghost node ids from old rebuilds, harmless: {0})" -f (($ghosts|ForEach-Object{$_.Name}) -join ', ')) DarkGray
			Problem 'INFO' "$($ghosts.Count) stale duplicate node id(s) in the milestone doc (old rebuilds). Cosmetic." "Ignore, or 'pwsh scripts\sync-reset.ps1 -Action unlock'." }
	} catch { W "  milestone unreachable: $($_.Exception.Message)" Yellow }
	W ""
}

# ============================ 3  CONFIG ============================
W "## 3  CONFIG (want: liveSync=False periodic=True int<=10 onSave=True onOpen=True)"
$cfgBad=@{}
function CheckCfg($label,$c){
	$ok = ($c.liveSync -eq $false) -and ($c.periodicReplication -eq $true) -and ([int]$c.periodicReplicationInterval -le 10) -and ($c.syncOnSave -eq $true) -and ($c.syncOnFileOpen -eq $true)
	W ("  {0,-7}: liveSync={1} periodic={2} int={3} onSave={4} onOpen={5} onStart={6}  [{7}]" -f $label,$c.liveSync,$c.periodicReplication,$c.periodicReplicationInterval,$c.syncOnSave,$c.syncOnFileOpen,$c.syncOnStart,$(if($ok){'OK'}else{'DRIFT'})) $(if($ok){'Gray'}else{'Yellow'})
	if (-not $ok){ $cfgBad[$label]=$true }
}
$lapCfg="$VaultDir\.obsidian\plugins\obsidian-livesync\data.json"
if (Test-Path $lapCfg){ CheckCfg 'master' (Get-Content $lapCfg -Raw | ConvertFrom-Json) }
if ($haveAdb){
	foreach ($d in $Android){
		if (-not $adbState[$d.name].up){ W ("  {0,-7}: OFFLINE (cannot read config)" -f $d.name) Yellow; continue }
		$raw=(& adb -s $adbState[$d.name].serial shell "cat '$($d.vault)/.obsidian/plugins/obsidian-livesync/data.json'" 2>$null) -join "`n"
		if ($raw){ CheckCfg $d.name ($raw | ConvertFrom-Json) } else { W ("  {0,-7}: config unreadable" -f $d.name) Yellow }
	}
}
if ($cfgBad.Keys.Count){ Problem 'MED' "Config drift on: $($cfgBad.Keys -join ', ') (fell out of reliable mode)." "pwsh scripts\sync-kick.ps1 -All" }
W ""

# ============================ 4  FILE STATE (md5) ============================
W "## 4  FILE STATE (cursor md5 per device; OK=identical across all, DIFF=someone lags now)"
$fileHashes=@{}
Get-ChildItem "$VaultDir\cursor-state\*.json" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.diag*' } | ForEach-Object {
	if(-not $fileHashes.ContainsKey($_.Name)){$fileHashes[$_.Name]=@{}}; $fileHashes[$_.Name]['master']=(Get-FileHash $_.FullName -Algorithm MD5).Hash.ToLower() }
if ($haveAdb){
	foreach ($d in $Android){
		if (-not $adbState[$d.name].up){ continue }
		$names=(& adb -s $adbState[$d.name].serial shell "ls $($d.vault)/cursor-state/*.json 2>/dev/null" 2>$null) | ForEach-Object { ($_ -split '/')[-1].Trim() } | Where-Object { $_ -and $_ -notlike '.diag*' }
		foreach ($nm in $names){ $md5=(& adb -s $adbState[$d.name].serial shell "md5sum $($d.vault)/cursor-state/$nm 2>/dev/null" 2>$null)
			if($md5){ if(-not $fileHashes.ContainsKey($nm)){$fileHashes[$nm]=@{}}; $fileHashes[$nm][$d.name]=(($md5 -split '\s+')[0]).Trim().ToLower() } }
	}
}
$anyDiff=$false
foreach ($f in ($fileHashes.Keys | Sort-Object)){
	$h=$fileHashes[$f]; $distinct=@($h.Values | Sort-Object -Unique)
	if ($distinct.Count -le 1){ W ("  [OK  ] {0}  ({1} device(s))" -f $f,$h.Count) Gray }
	else { $anyDiff=$true; W ("  [DIFF] {0}" -f $f) Yellow; foreach($k in $h.Keys){ W ("          {0,-8} {1}" -f $k,$h[$k]) } }
}
if ($anyDiff){ Problem 'LOW' "Cursor files differ across devices right now. If the LIVE PROBE below passes, this is just propagation lag (often a backgrounded phone). If the probe also fails, a device is genuinely stuck." "Foreground the lagging device; if it persists 'pwsh scripts\sync-kick.ps1 -All'." }
W ""

# ============================ 5  LIVE PROBE (active end-to-end) ============================
W "## 5  LIVE PROBE (active: marker master -> CouchDB -> each device)"
if ($NoProbe){ W "  (skipped: -NoProbe)" DarkGray }
elseif (-not $couchUp){ W "  (skipped: CouchDB is down)" Yellow }
else {
	$token = "CHECKUP-$ts-$($env:COMPUTERNAME)"
	$probeFile = Join-Path $VaultDir 'sync-probe.md'
	[System.IO.File]::WriteAllText($probeFile, "sync probe`n`n$token`n", $enc)
	W "  wrote marker '$token' to $probeFile"
	$seqStart=$seq0; $pushAt=$null; $deadline=(Get-Date).AddSeconds($ProbeTimeout)
	$targets = @{}
	if ($haveAdb){ foreach($d in $Android){ if($adbState[$d.name].up){ $targets[$d.name]=$d.vault } } }
	$gotAt=@{}; $startT=Get-Date
	while ((Get-Date) -lt $deadline){
		Start-Sleep -Seconds 3
		$el=[math]::Round(((Get-Date)-$startT).TotalSeconds)
		if (-not $pushAt){ try { $s=[int]((Invoke-RestMethod $DbUrl -Headers $Auth -TimeoutSec 6).update_seq -split '-')[0]
			if ($s -gt $seqStart){ $pushAt=$el; W ("  master PUSHED to CouchDB at ~${el}s (update_seq $seqStart -> $s)" -f $el) Green } } catch {} }
		foreach ($name in @($targets.Keys)){
			if ($gotAt.ContainsKey($name)){ continue }
			$hit=(& adb -s $adbState[$name].serial shell "grep -l '$token' '$($targets[$name])/sync-probe.md' 2>/dev/null" 2>$null)
			if ($hit){ $gotAt[$name]=$el; W ("  $name RECEIVED marker at ~${el}s") Green }
		}
		if ($pushAt -and $targets.Keys.Count -gt 0 -and ($gotAt.Keys.Count -ge $targets.Keys.Count)){ break }
	}
	if (-not $pushAt){ W "  master did NOT push the marker within ${ProbeTimeout}s -- master LiveSync isn't replicating (or its file watcher missed the new file; focus Obsidian on the master)." Red
		Problem 'HIGH' "The master failed to push a fresh change to CouchDB in ${ProbeTimeout}s -- master replication is stuck." "Reload master Obsidian (Ctrl+R) or 'pwsh scripts\sync-kick.ps1 -All'. If WSL localhost forwarding dropped, 'wsl --shutdown' + restart CouchDB." }
	foreach ($name in @($targets.Keys)){
		if (-not $gotAt.ContainsKey($name)){
			$why = if (-not $adbState[$name].obsidian){ "its Obsidian is NOT running -> open it (mobile syncs only foregrounded)" } else { "Obsidian is running but it didn't pull in ${ProbeTimeout}s -> likely backgrounded or replication stuck" }
			W ("  $name did NOT receive the marker in ${ProbeTimeout}s -- $why") Yellow
			Problem 'MED' "$name never received the live marker in ${ProbeTimeout}s ($why)." "Foreground Obsidian on $name and re-run. If still failing: 'pwsh scripts\sync-kick.ps1 -All'." }
	}
	if ($haveAdb -and $targets.Keys.Count -eq 0){ W "  (no Android device was adb-reachable to receive the marker)" Yellow }
	W "  NOTE: the 2nd laptop ('Notes') can't be probed from here -- run this script ON that laptop to test it."
}
W ""

# ============================ 6  LOGS ============================
W "## 6  LOGS (recent activity)"
$mlog=Get-ChildItem "$VaultDir\rcp-enhanced-logs\*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($mlog){ W "  -- master RCP-E $($mlog.Name) (tail) --"; Get-Content $mlog.FullName -Tail 6 -Encoding UTF8 | ForEach-Object { W "     $_" } } else { W "  (no master RCP-E log -- logging off, which is correct for normal running)" DarkGray }
if ($haveAdb){
	foreach ($d in $Android){
		if (-not $adbState[$d.name].up){ continue }
		$diag=(& adb -s $adbState[$d.name].serial shell "cat $($d.vault)/cursor-state/.diag-*.json 2>/dev/null" 2>$null) -join "`n"
		if ($diag){ try { $ev=($diag | ConvertFrom-Json).events | Select-Object -Last 3
			W "  -- $($d.name) recent sync decisions --"; $ev | ForEach-Object { W "     $($_.ts) $($_.event) trigger=$($_.trigger) winner=$($_.winnerDeviceId)" } } catch {} }
	}
}
W ""

# ============================ VERDICT ============================
W "## VERDICT"
if ($problems.Count -eq 0){
	W "  ALL GREEN. Connections up, configs reliable, files identical, live marker reached every device. Sync is healthy." Green
} else {
	$order=@{ CRITICAL=0; HIGH=1; MED=2; LOW=3; INFO=4 }
	$ranked=$problems | Sort-Object { $order[$_.sev] }
	foreach ($p in $ranked){
		$col=switch($p.sev){'CRITICAL'{'Red'}'HIGH'{'Red'}'MED'{'Yellow'}default{'Gray'}}
		W ("  [{0}] {1}" -f $p.sev,$p.msg) $col
		W ("        FIX: {0}" -f $p.fix) $col
	}
	W ""
	W ("  >>> START HERE: {0}" -f $ranked[0].fix) Cyan
}
W ""
W "## FOR COPILOT / CODE CLOUD"
W "  Paste this whole file and ask: 'This is my Obsidian LiveSync cursor-sync checkup. Using section 0"
W "  for context, tell me which device or layer is failing, why, and the exact fix.' The VERDICT is my"
W "  heuristic; cross-check it against sections 1-6 (esp. the LIVE PROBE in 5 and md5 in 4)."

[System.IO.File]::WriteAllText($report, ($lines -join "`r`n"), $enc)
Write-Host ""
Write-Host "==> Checkup report saved: $report" -ForegroundColor Green
Write-Host "    Open it and paste the contents into Copilot / Code Cloud to analyze." -ForegroundColor Green
