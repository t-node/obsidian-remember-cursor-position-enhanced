<#
.SYNOPSIS
  Gather RCP-E logs + sync-decision (.diag) files from every device into one folder, and surface the
  events that explain a SNAP-BACK (your scroll resetting to a default position). Run it right after a
  snap-back, then send me the printed report.

.DESCRIPTION
  Pulls, from the master + every adb-reachable device:
    - rcp-enhanced-logs/<deviceId>.log   (full RCP-E activity, if logging is enabled)
    - cursor-state/.diag-<deviceId>.json (recent merge decisions: which device's position won, why)
  Then it scans for the tell-tale snap-back signature: a REMOTE device's weak/top-of-note position being
  APPLIED over your real scroll, or a CLOCK SKEW that made the wrong position win.

  IMPORTANT: full logs only exist if RCP-E "Log to file" + "Debug logging" are ON. Turn them on in
  RCP-E settings on each device (they stay LOCAL -- LiveSync ignores the log folder, so no flood).
  The .diag files are always written, but only keep the last ~N events, so collect SOON after it happens.

.PARAMETER VaultDir   Master vault (from sync.config.ps1 if omitted).

.EXAMPLE
  pwsh scripts\collect-logs.ps1        # run right after a snap-back, then send me the report
#>
[CmdletBinding()]
param([string]$VaultDir)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_sync-config.ps1"
$haveAdb = $null -ne (Get-Command adb -ErrorAction SilentlyContinue)
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path (Split-Path $PSScriptRoot -Parent) "debug-reports\rcp-logs-$ts"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$summary = New-Object System.Collections.Generic.List[string]
function S($s,$c){ $summary.Add(($s -replace '\e\[[0-9;]*m','')); if($c){Write-Host $s -ForegroundColor $c}else{Write-Host $s} }

S "===== RCP-E LOG COLLECTION  $ts =====" Cyan
S "Looking for SNAP-BACK evidence: a remote/weak position applied over your real scroll, or clock skew."
S ""

# ---- gather: master (local) ----
$logDir = Join-Path $VaultDir 'rcp-enhanced-logs'
$csDir  = Join-Path $VaultDir 'cursor-state'
$collected = @()
if (Test-Path $logDir) { Get-ChildItem "$logDir\*.log" -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item $_.FullName (Join-Path $outDir "master-$($_.Name)") -Force; $collected += "master:$($_.Name)" } }
Get-ChildItem "$csDir\.diag-*.json" -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item $_.FullName (Join-Path $outDir "master-$($_.Name)") -Force; $collected += "master:$($_.Name)" }

# ---- gather: adb devices ----
if ($haveAdb) {
	foreach ($d in $SyncConfig.Devices) {
		$serial = "$($d.ip):5555"
		if ((& adb connect $serial 2>&1 | Select-Object -Last 1) -notmatch 'connected') { S "  $($d.name): OFFLINE (can't pull logs)" Yellow; continue }
		# logs
		$logs = (& adb -s $serial shell "ls $($d.vault)/rcp-enhanced-logs/*.log 2>/dev/null" 2>$null) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
		foreach ($lf in $logs) { $base=($lf -split '/')[-1]; & adb -s $serial pull "$lf" (Join-Path $outDir "$($d.name)-$base") 2>$null | Out-Null; $collected += "$($d.name):$base" }
		# diag
		$diags = (& adb -s $serial shell "ls $($d.vault)/cursor-state/.diag-*.json 2>/dev/null" 2>$null) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
		foreach ($df in $diags) { $base=($df -split '/')[-1]; & adb -s $serial pull "$df" (Join-Path $outDir "$($d.name)-$base") 2>$null | Out-Null; $collected += "$($d.name):$base" }
	}
} else { S "  adb not installed -- only the master's logs collected. Run on a machine with adb, or copy the device logs manually." Yellow }

S ("Collected: {0} file(s) -> {1}" -f $collected.Count,$outDir) Green
S ""

# ---- scan for snap-back signatures ----
S "=== SNAP-BACK SCAN (merge decisions where a position was APPLIED over your scroll) ===" Cyan
$applied = @(); $skew = @()
Get-ChildItem "$outDir\*.log" -ErrorAction SilentlyContinue | ForEach-Object {
	$dev = $_.BaseName
	Get-Content $_.FullName -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
		if ($_ -match 'Merged state applied|Applied merged|applyState' -and $_ -notmatch 'not applied|rejected') { $applied += "[$dev] $_" }
		if ($_ -match 'Clock skew') { $skew += "[$dev] $_" }
	}
}
Get-ChildItem "$outDir\*.diag-*.json" -ErrorAction SilentlyContinue | ForEach-Object {
	$dev = $_.BaseName
	try { $ev = (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).events
		$ev | Where-Object { $_.event -match 'applied' -and $_.event -notmatch 'rejected' } | ForEach-Object { $applied += "[$dev] $($_.ts) winner=$($_.winnerDeviceId) note=$($_.notePath)" }
	} catch {}
}
if ($skew.Count) { S "  CLOCK SKEW warnings (a wrong clock can make the wrong position win):" Yellow; $skew | Select-Object -Last 5 | ForEach-Object { S "    $_" } }
if ($applied.Count) { S "  Times a merged (remote) position was APPLIED -- if one overrode your scroll, it's here:" Yellow; $applied | Select-Object -Last 12 | ForEach-Object { S "    $_" } }
else { S "  No 'applied remote position' events found in the collected logs." Gray }
if (-not (Get-ChildItem "$outDir\*.log" -ErrorAction SilentlyContinue)) {
	S "" ; S "  !! No full .log files found -> RCP-E 'Log to file' is OFF. Turn it ON (see note below) so the NEXT" Yellow
	S "     snap-back is captured in detail. Right now only the short .diag history is available." Yellow
}
S ""
S "## HOW TO ENABLE FULL LOGGING (do this on each device, esp. the phone)" Cyan
S "  RCP-E plugin settings -> turn ON 'Log to file' AND 'Debug logging'. Logs stay LOCAL (LiveSync ignores"
S "  the rcp-enhanced-logs folder, so they will NOT flood sync). Then, right after a snap-back, run this"
S "  script and send me the folder above."

[System.IO.File]::WriteAllText((Join-Path $outDir "SUMMARY.txt"), ($summary -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ""
Write-Host "==> Logs + summary saved to: $outDir" -ForegroundColor Green
Write-Host "    Send me that folder (or paste SUMMARY.txt) after a snap-back and I'll find the cause." -ForegroundColor Green
