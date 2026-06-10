<#
.SYNOPSIS
  ONE command that captures the full cross-device sync state into a single report file you can
  send to Claude: "here are the logs, what's mismatching?"

.DESCRIPTION
  Run on the master laptop (where CouchDB lives). It gathers, into debug-reports\sync-report-<time>.txt:
    1. CouchDB health + whether replication is actually MOVING (update_seq over 12s).
    2. Every sync node CouchDB has ever seen + how long since each last synced (ACTIVE/recent/STALE)
       - this is how you check the Windows laptops too, since they can't be adb'd into.
    3. Sync-mode config for the master + every reachable Android device (catches config drift).
    4. A cursor-state md5 comparison across master + phone + tablet (OK = identical / DIFF = lagging).
    5. The tail of each reachable device's RCP-E log + sync-diagnostic file.
  Run it ALSO on each laptop (copy the scripts folder there) to capture that laptop's local config.

.EXAMPLE
  pwsh scripts/sync-report.ps1
  # then send the printed file path's contents to Claude
#>
[CmdletBinding()]
param(
	[string]$CouchUrl = 'http://127.0.0.1:5984',
	[string]$CouchUser,
	[string]$CouchPass,
	[string]$DbName,
	[string]$VaultDir
)
. "$PSScriptRoot\_sync-config.ps1"
$ErrorActionPreference = 'Continue'
$DbUrl = "$CouchUrl/$DbName"
$AuthHeader = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${CouchUser}:${CouchPass}")))" }
$Devices = $SyncConfig.Devices
# The REAL devices: laptop(notes1) + phone(Test) + tablet(ObsidianVault) + new laptop(Notes).
# (ytt2gvef = retired 2nd laptop's leftover file, ignored.)
$KnownVaults = @('notes1','Test','ObsidianVault','Notes')

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'debug-reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$report = Join-Path $reportDir "sync-report-$ts.txt"
$lines = New-Object System.Collections.Generic.List[string]
function W($s){ $lines.Add($s); Write-Host $s }

W "===== CURSOR-SYNC REPORT  $ts ====="
W "machine: $env:COMPUTERNAME   vault: $VaultDir"
W ""

# 1. CouchDB + is replication moving
try {
	$i1 = Invoke-RestMethod $DbUrl -Headers $AuthHeader -TimeoutSec 8
	$s1 = [int](($i1.update_seq -split '-')[0])
	Start-Sleep -Seconds 12
	$i2 = Invoke-RestMethod $DbUrl -Headers $AuthHeader -TimeoutSec 8
	$s2 = [int](($i2.update_seq -split '-')[0])
	W "[CouchDB] docs=$($i2.doc_count) active=$([math]::Round($i2.sizes.active/1MB,1))MB lock=$((Invoke-RestMethod "$DbUrl/_local%2Fobsydian_livesync_milestone" -Headers $AuthHeader).locked)"
	W "[CouchDB] update_seq moved $($s2-$s1) in 12s  ($(if($s2-$s1 -gt 0){'replication ACTIVE'}else{'idle - scroll something while this runs to test'}))"
} catch { W "[CouchDB] UNREACHABLE from here: $($_.Exception.Message)" }
W ""

# 2. Every node + freshness (covers laptops without adb)
try {
	$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	$m = Invoke-RestMethod "$DbUrl/_local%2Fobsydian_livesync_milestone" -Headers $AuthHeader
	W "[NODES] every device CouchDB has seen:"
	$m.node_info.PSObject.Properties | Sort-Object { $_.Value.last_connected } -Descending | ForEach-Object {
		$sec = [math]::Round(($now - $_.Value.last_connected)/1000)
		$tag = if ($sec -lt 90) { 'ACTIVE' } elseif ($sec -lt 600) { 'recent' } else { 'STALE ' }
		$age = if ($sec -lt 120) { "$sec s" } else { "$([math]::Round($sec/60)) min" }
		W ("   [{0}] {1,-12} vault='{2}'  {3} ago" -f $tag,$_.Name,$_.Value.vault_name,$age)
	}
	$seen = @($m.node_info.PSObject.Properties.Value.vault_name | Sort-Object -Unique)
	$missing = $KnownVaults | Where-Object { $_ -notin $seen }
	if ($missing) { W "   !! NEVER-SEEN vaults (not syncing at all): $($missing -join ', ')" }
} catch { W "[NODES] milestone unreachable: $($_.Exception.Message)" }
W ""

# helper: connect android + read
function AdbRead($serial,$path){ (& adb -s $serial shell "cat '$path'" 2>$null) -join "`n" }

# 3 + 4 + 5: per-device config, cursor md5, logs
$haveAdb = $null -ne (Get-Command adb -ErrorAction SilentlyContinue)
$fileHashes = @{}   # file -> @{ device -> md5 }

function RecordLocalCursor($label,$dir){
	Get-ChildItem "$dir\*.json" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.diag*' } | ForEach-Object {
		if (-not $fileHashes.ContainsKey($_.Name)) { $fileHashes[$_.Name]=@{} }
		$fileHashes[$_.Name][$label] = (Get-FileHash $_.FullName -Algorithm MD5).Hash.ToLower()
	}
}

W "[CONFIG] sync mode per reachable device (want: liveSync=False periodic=True interval<=10 syncOnSave=True syncOnFileOpen=True):"
# master (local)
$lapCfgPath = "$VaultDir\.obsidian\plugins\obsidian-livesync\data.json"
if (Test-Path $lapCfgPath) {
	$c = Get-Content $lapCfgPath -Raw | ConvertFrom-Json
	W ("   {0,-7}: liveSync={1} periodic={2} int={3} onSave={4} onOpen={5} onStart={6} history={7}" -f 'master',$c.liveSync,$c.periodicReplication,$c.periodicReplicationInterval,$c.syncOnSave,$c.syncOnFileOpen,$c.syncOnStart,$c.useHistory)
}
RecordLocalCursor 'master' "$VaultDir\cursor-state"
if ($haveAdb) {
	foreach ($d in $Devices) {
		$serial = "$($d.ip):5555"
		$null = & adb connect $serial 2>$null
		$raw = AdbRead $serial "$($d.vault)/.obsidian/plugins/obsidian-livesync/data.json"
		if ($raw) {
			$c = $raw | ConvertFrom-Json
			W ("   {0,-7}: liveSync={1} periodic={2} int={3} onSave={4} onOpen={5} onStart={6} history={7}" -f $d.name,$c.liveSync,$c.periodicReplication,$c.periodicReplicationInterval,$c.syncOnSave,$c.syncOnFileOpen,$c.syncOnStart,$c.useHistory)
		} else { W ("   {0,-7}: OFFLINE (adb {1} unreachable)" -f $d.name,$serial) }
		# cursor md5s
		$names = (& adb -s $serial shell "ls $($d.vault)/cursor-state/*.json 2>/dev/null" 2>$null) | ForEach-Object { ($_ -split '/')[-1].Trim() } | Where-Object { $_ -and $_ -notlike '.diag*' }
		foreach ($nm in $names) {
			$md5 = (& adb -s $serial shell "md5sum $($d.vault)/cursor-state/$nm 2>/dev/null" 2>$null)
			if ($md5) { if (-not $fileHashes.ContainsKey($nm)){$fileHashes[$nm]=@{}}; $fileHashes[$nm][$d.name]=(($md5 -split '\s+')[0]).Trim().ToLower() }
		}
	}
} else { W "   (adb not installed here - only this machine's config shown)" }
W ""

W "[CURSOR-STATE] md5 across reachable devices (OK=identical, DIFF=lagging this instant):"
foreach ($f in ($fileHashes.Keys | Sort-Object)) {
	$h = $fileHashes[$f]
	$distinct = @($h.Values | Sort-Object -Unique)
	$state = if ($distinct.Count -le 1) { 'OK  ' } else { 'DIFF' }
	W ("   [{0}] {1}" -f $state,$f)
	if ($state -eq 'DIFF') { foreach ($k in $h.Keys) { W ("        {0,-8} {1}" -f $k,$h[$k]) } }
}
W ""

# 5. RCP-E logs (master + android tails)
W "[LOGS] recent RCP-E activity (last lines):"
$mlog = Get-ChildItem "$VaultDir\rcp-enhanced-logs\*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($mlog) { W "  --- master $($mlog.Name) ---"; Get-Content $mlog.FullName -Tail 8 | ForEach-Object { W "    $_" } }
if ($haveAdb) {
	foreach ($d in $Devices) {
		$serial = "$($d.ip):5555"
		$diag = (& adb -s $serial shell "cat $($d.vault)/cursor-state/.diag-*.json 2>/dev/null" 2>$null) -join "`n"
		if ($diag) {
			try { $ev = ($diag | ConvertFrom-Json).events | Select-Object -Last 3
				W "  --- $($d.name) recent sync decisions ---"
				$ev | ForEach-Object { W "    $($_.ts) $($_.event) trigger=$($_.trigger) winner=$($_.winnerDeviceId)" }
			} catch {}
		}
	}
}

[System.IO.File]::WriteAllText($report, ($lines -join "`r`n"))
Write-Host ""
Write-Host "==> Report saved: $report" -ForegroundColor Green
Write-Host "    Send that file's contents to Claude to diagnose any sync issue instantly." -ForegroundColor Green
