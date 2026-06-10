<#
.SYNOPSIS
  THE "where is the sync broken?" doctor. Read-only. Run it, read the VERDICT, run the one
  command it tells you. Also saves a shareable report you can paste to Claude.

.DESCRIPTION
  Checks every layer of the sync, in order, and pinpoints the FIRST thing that is wrong:
    LAYER 1  CouchDB itself (local 127.0.0.1)        -> is the database even up?
    LAYER 2  Tailscale Serve (remote URL)            -> can remote devices reach it?
    LAYER 3  replication movement (update_seq)       -> is anything actually flowing?
    LAYER 4  per-device freshness (every node)       -> which device went dark, and how long?
    LAYER 5  per-device config drift                 -> did a device fall out of reliable mode?
    LAYER 6  cursor-state md5 across devices         -> who is lagging this instant?
  Then it prints a VERDICT: the single most likely problem + the exact command to fix it.

  It changes NOTHING. Safe to run anytime. For the live push/pull test add -Watch and scroll
  a note on any device while it runs.

.PARAMETER Watch        Watch update_seq for N seconds so you can SEE a scroll propagate.
.PARAMETER WatchSeconds How long to watch (default 30).

.EXAMPLE
  pwsh scripts\sync-diagnose.ps1
  pwsh scripts\sync-diagnose.ps1 -Watch          # then scroll a note on a device
#>
[CmdletBinding()]
param(
	[switch]$Watch,
	[int]$WatchSeconds = 30,
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

# Known real devices: vault name + (for android) Tailscale IP + on-device vault path.
$KnownVaults = @('notes1','Test','ObsidianVault','Notes')
$Android = $SyncConfig.Devices

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'debug-reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$report = Join-Path $reportDir "sync-diagnose-$ts.txt"
$lines = New-Object System.Collections.Generic.List[string]
$problems = New-Object System.Collections.Generic.List[object]
function W($s,$c){ $lines.Add(($s -replace '\e\[[0-9;]*m','')); if($c){Write-Host $s -ForegroundColor $c}else{Write-Host $s} }
function Problem($sev,$msg,$fix){ $problems.Add([pscustomobject]@{sev=$sev;msg=$msg;fix=$fix}) }

W "===== SYNC DIAGNOSE  $ts =====" Cyan
W "machine: $env:COMPUTERNAME   master vault: $VaultDir"
W ""

# ---------- LAYER 1: CouchDB up? (this is the hub; if it's down, nothing else matters) ----------
$couchUp = $false; $seq1 = $null
try {
	$db = Invoke-RestMethod $DbUrl -Headers $Auth -TimeoutSec 8
	$couchUp = $true
	$seq1 = [int](($db.update_seq -split '-')[0])
	W ("[1] CouchDB (local 127.0.0.1): UP  docs={0} size={1}MB seq={2}" -f $db.doc_count,[math]::Round($db.sizes.active/1MB,1),$seq1) Green
} catch {
	W "[1] CouchDB (local 127.0.0.1): DOWN -- $($_.Exception.Message)" Red
	Problem 'CRITICAL' "CouchDB is not reachable at $DbUrl. The whole sync is down because the hub is down." "Start WSL + CouchDB:  wsl -d <distro>  then start couchdb (or 'sudo service couchdb start'). Re-run this script."
}

# ---------- LAYER 2: Tailscale Serve (the path remote devices use) ----------
if ($couchUp) {
	try {
		$null = Invoke-RestMethod $TsDbUrl -Headers $Auth -TimeoutSec 12
		W "[2] Tailscale Serve (remote URL): UP  (phone/tablet/other-laptop can reach CouchDB)" Green
	} catch {
		$m = $_.Exception.Message
		W "[2] Tailscale Serve (remote URL): DOWN -- $m" Red
		Problem 'HIGH' "Remote devices cannot reach CouchDB over Tailscale ($TsDbUrl). The master is fine (it uses 127.0.0.1) but phone/tablet/other-laptop are cut off." "On the master: ensure Tailscale is Connected, then re-run:  tailscale serve --bg --https=443 127.0.0.1:5984"
	}
}

# ---------- LAYER 3: is replication actually moving? ----------
if ($couchUp) {
	Start-Sleep -Seconds 10
	try {
		$db2 = Invoke-RestMethod $DbUrl -Headers $Auth -TimeoutSec 8
		$seq2 = [int](($db2.update_seq -split '-')[0])
		$moved = $seq2 - $seq1
		if ($moved -gt 0) { W "[3] Replication: MOVING (update_seq +$moved in 10s) -- data is flowing" Green }
		else { W "[3] Replication: idle (update_seq did not move in 10s). Normal if nobody is scrolling; use -Watch to test." Yellow }
	} catch { W "[3] Replication: could not re-read seq" Yellow }
}

# ---------- LAYER 4: per-device freshness ----------
$seen = @()
if ($couchUp) {
	try {
		$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
		$mile = Invoke-RestMethod "$DbUrl/_local%2Fobsydian_livesync_milestone" -Headers $Auth -TimeoutSec 8
		W ""
		W "[4] Devices CouchDB has seen (most recent first):"
		$mile.node_info.PSObject.Properties | Sort-Object { $_.Value.last_connected } -Descending | ForEach-Object {
			$sec = [math]::Round(($now - $_.Value.last_connected)/1000)
			$tag = if ($sec -lt 90){'ACTIVE'} elseif ($sec -lt 600){'recent'} else {'STALE '}
			$age = if ($sec -lt 120){"$sec s"} else {"$([math]::Round($sec/60)) min"}
			$col = if ($tag -eq 'STALE '){'Yellow'} else {'Gray'}
			W ("    [{0}] {1,-12} vault='{2}'  {3} ago" -f $tag,$_.Name,$_.Value.vault_name,$age) $col
		}
		$seen = @($mile.node_info.PSObject.Properties.Value.vault_name | Sort-Object -Unique)
		$missing = $KnownVaults | Where-Object { $_ -notin $seen }
		if ($missing) {
			W "    !! NEVER-SEEN vaults (never connected): $($missing -join ', ')" Red
			Problem 'HIGH' "These devices have never synced: $($missing -join ', '). Their LiveSync isn't configured/connected." "On that device run:  pwsh scripts\fix-this-laptop.ps1   (laptop)  -- or finish the LiveSync setup wizard (mobile)."
		}
		# Dedupe by vault: the FRESHEST node per vault is the real device; older same-vault IDs
		# are ghosts left over from past rebuilds. Only judge the real (freshest) device, and
		# list ghosts separately as a cleanup item -- not as "gone dark".
		$byVault = $mile.node_info.PSObject.Properties | Group-Object { $_.Value.vault_name }
		$ghosts = @()
		foreach ($g in $byVault) {
			$ordered = $g.Group | Sort-Object { $_.Value.last_connected } -Descending
			$real = $ordered[0]
			$ghosts += $ordered | Select-Object -Skip 1
			$sec = [math]::Round(($now - $real.Value.last_connected)/1000)
			# NB: milestone freshness is a WEAK signal -- LiveSync only stamps last_connected when a
			# node actually exchanges data, not on idle polls, so a healthy-but-idle device looks old.
			# So: skip the master (we're ON it; its config above is the truth) and only warn past 60 min.
			if ($g.Name -eq 'notes1') { continue }
			if ($sec -ge 3600 -and $g.Name -in $KnownVaults) {
				Problem 'LOW' "Device '$($g.Name)' hasn't exchanged data in $([math]::Round($sec/60)) min -- likely idle or its Obsidian is closed (only a problem if you expect it live right now)." "Mobile: open Obsidian and look at a note (it only syncs foregrounded). Laptop: reload (Ctrl+R) or  pwsh scripts\sync-kick.ps1 -All"
			}
		}
		if ($ghosts.Count) {
			W ("    (ghost nodes from old rebuilds, harmless: {0})" -f (($ghosts | ForEach-Object { $_.Name }) -join ', ')) DarkGray
			Problem 'INFO' "$($ghosts.Count) stale duplicate node id(s) linger in the milestone doc (from past rebuilds). Harmless, just clutter." "Optional cleanup:  pwsh scripts\sync-reset.ps1 -Action unlock   (or leave them -- they don't affect sync)."
		}
	} catch { W "[4] milestone unreachable: $($_.Exception.Message)" Yellow }
}

# ---------- LAYER 5 + 6: config drift + cursor md5 across reachable devices ----------
$haveAdb = $null -ne (Get-Command adb -ErrorAction SilentlyContinue)
$cfgBad = @{}            # vault -> reason
$fileHashes = @{}       # filename -> @{ device -> md5 }
function CheckCfg($label,$c){
	$ok = ($c.liveSync -eq $false) -and ($c.periodicReplication -eq $true) -and ([int]$c.periodicReplicationInterval -le 10) -and ($c.syncOnSave -eq $true) -and ($c.syncOnFileOpen -eq $true)
	$flag = if($ok){'OK'}else{'DRIFT'}
	W ("    {0,-7}: liveSync={1} periodic={2} int={3} onSave={4} onOpen={5}  [{6}]" -f $label,$c.liveSync,$c.periodicReplication,$c.periodicReplicationInterval,$c.syncOnSave,$c.syncOnFileOpen,$flag) $(if($ok){'Gray'}else{'Yellow'})
	if (-not $ok) { $cfgBad[$label] = $true }
}
W ""
W "[5] Sync-mode per reachable device (want: liveSync=False periodic=True int<=10 onSave/onOpen=True):"
$lapCfg = "$VaultDir\.obsidian\plugins\obsidian-livesync\data.json"
if (Test-Path $lapCfg) { CheckCfg 'master' (Get-Content $lapCfg -Raw | ConvertFrom-Json) }
Get-ChildItem "$VaultDir\cursor-state\*.json" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.diag*' } | ForEach-Object {
	if (-not $fileHashes.ContainsKey($_.Name)){$fileHashes[$_.Name]=@{}}
	$fileHashes[$_.Name]['master'] = (Get-FileHash $_.FullName -Algorithm MD5).Hash.ToLower()
}
if ($haveAdb) {
	foreach ($d in $Android) {
		$serial = "$($d.ip):5555"
		$null = & adb connect $serial 2>$null
		$raw = (& adb -s $serial shell "cat '$($d.vault)/.obsidian/plugins/obsidian-livesync/data.json'" 2>$null) -join "`n"
		if ($raw) { CheckCfg $d.name ($raw | ConvertFrom-Json) }
		else { W ("    {0,-7}: OFFLINE (adb {1} unreachable -- rebooted? USB once + adb-net.ps1 -Enable)" -f $d.name,$serial) Yellow }
		$names = (& adb -s $serial shell "ls $($d.vault)/cursor-state/*.json 2>/dev/null" 2>$null) | ForEach-Object { ($_ -split '/')[-1].Trim() } | Where-Object { $_ -and $_ -notlike '.diag*' }
		foreach ($nm in $names) {
			$md5 = (& adb -s $serial shell "md5sum $($d.vault)/cursor-state/$nm 2>/dev/null" 2>$null)
			if ($md5) { if(-not $fileHashes.ContainsKey($nm)){$fileHashes[$nm]=@{}}; $fileHashes[$nm][$d.name]=(($md5 -split '\s+')[0]).Trim().ToLower() }
		}
	}
} else { W "    (adb not installed here -- only the master's config/cursors shown)" DarkGray }
if ($cfgBad.Keys.Count) {
	Problem 'MED' "Config drift on: $($cfgBad.Keys -join ', '). They fell out of reliable mode (live connection stalls + suppresses the periodic fallback)." "pwsh scripts\sync-kick.ps1 -All   (re-asserts reliable mode on every device)"
}

W ""
W "[6] Cursor-state md5 across devices (OK=identical, DIFF=lagging this instant):"
$anyDiff = $false
foreach ($f in ($fileHashes.Keys | Sort-Object)) {
	$h = $fileHashes[$f]
	$distinct = @($h.Values | Sort-Object -Unique)
	if ($distinct.Count -le 1) { W ("    [OK  ] {0}" -f $f) Gray }
	else {
		$anyDiff = $true
		W ("    [DIFF] {0}" -f $f) Yellow
		foreach ($k in $h.Keys) { W ("           {0,-8} {1}" -f $k,$h[$k]) }
	}
}
if ($anyDiff) {
	Problem 'LOW' "Some cursor files differ across devices right now. If replication is MOVING this is just propagation lag (resolves in seconds). If it persists with idle seq, a device is stuck." "Give it ~10s and re-run. If still DIFF:  pwsh scripts\sync-kick.ps1 -All"
}

# ---------- optional live test ----------
if ($Watch -and $couchUp) {
	W ""
	W "[WATCH] Scroll a note on ANY device now. Watching update_seq for $WatchSeconds s..." Cyan
	$base = $seq1; $end = (Get-Date).AddSeconds($WatchSeconds); $last = $base
	while ((Get-Date) -lt $end) {
		Start-Sleep -Seconds 2
		try { $s = [int]((Invoke-RestMethod $DbUrl -Headers $Auth -TimeoutSec 6).update_seq -split '-')[0]
			if ($s -ne $last) { W ("    seq {0}  (+{1})  <- a device just pushed" -f $s,($s-$last)) Green; $last = $s } } catch {}
	}
	if ($last -eq $base) { W "    seq never moved -- pushing is broken on whatever device you scrolled (check that device's config + that its Obsidian is in the foreground)." Yellow
		Problem 'MED' "While watching, no device managed to push a scroll to CouchDB." "On the device you scrolled: ensure Obsidian is foregrounded (mobile) and run pwsh scripts\sync-kick.ps1 -All" }
	else { W ("    Total movement: +{0}. Pushing works." -f ($last-$base)) Green }
}

# ---------- VERDICT ----------
W ""
W "==================== VERDICT ====================" Cyan
if ($problems.Count -eq 0) {
	W "  ALL GREEN. CouchDB up, devices reachable, configs in reliable mode, cursors converged." Green
	W "  If a device still feels stale: open its Obsidian and look at a note for a few seconds (mobile only syncs in the foreground)." Gray
} else {
	$order = @{ CRITICAL=0; HIGH=1; MED=2; LOW=3; INFO=4 }
	$ranked = $problems | Sort-Object { $order[$_.sev] }
	$i = 0
	foreach ($p in $ranked) {
		$i++
		$col = switch ($p.sev){ 'CRITICAL'{'Red'} 'HIGH'{'Red'} 'MED'{'Yellow'} default{'Gray'} }
		W ("  [{0}] {1}" -f $p.sev,$p.msg) $col
		W ("        FIX: {0}" -f $p.fix) $col
	}
	W ""
	W ("  >>> START HERE: {0}" -f $ranked[0].fix) Cyan
}

[System.IO.File]::WriteAllText($report, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ""
Write-Host "==> Shareable report saved: $report" -ForegroundColor Green
Write-Host "    Paste its contents to Claude: 'here's the sync status, what's wrong?'" -ForegroundColor Green
