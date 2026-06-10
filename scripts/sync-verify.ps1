<#
.SYNOPSIS
  Proves (or disproves) that EVERY note on EVERY device is in perfect sync -- byte-for-byte.
  Where sync-checkup tests the sync PIPELINE, this tests the ACTUAL CONTENT of the whole vault.

.DESCRIPTION
  Builds a manifest (relative-path -> md5) of every real file in the vault on the master and on
  each reachable Android device, then diffs them. For each device it reports, vs the master:
     IDENTICAL  - same path, same md5 (in sync)
     LAGGING    - master has a newer/different version the device hasn't pulled
     MISSING    - file exists on master but not on the device (device hasn't pulled it)
     EXTRA      - file exists on the device but not on master (device hasn't pushed it)
  PERFECT SYNC = every reachable device matches the master exactly (0 lagging / missing / extra).

  Excludes per-device, non-synced clutter: .obsidian/, rcp-enhanced-logs/, debug-reports/, .trash/,
  cursor-state/.diag-* and the sync-probe.md marker.

  NOTE: a backgrounded phone/tablet legitimately lags (Android only syncs foregrounded). Foreground
  it and re-run to confirm true parity. Writes a shareable report for Copilot / Code Cloud.

.PARAMETER ShowFiles  Max example file paths to list per mismatch category (default 15).

.EXAMPLE
  pwsh scripts\sync-verify.ps1
  pwsh scripts\sync-verify.ps1 -ShowFiles 50
#>
[CmdletBinding()]
param(
	[int]$ShowFiles = 15,
	[string]$VaultDir
)
. "$PSScriptRoot\_sync-config.ps1"
$ErrorActionPreference = 'Continue'
$Android = $SyncConfig.Devices
$enc = New-Object System.Text.UTF8Encoding($false)
# relative-path patterns to ignore: per-device app config (.obsidian at ANY depth), this plugin's
# logs/reports, Obsidian trash, Syncthing metadata (.stfolder/.stignore/.stversions -- a SEPARATE
# sync tool, not LiveSync), the diag files and the probe marker. Everything left is a real synced note/asset.
$IgnoreRx = '(^|/)\.obsidian/|(^|/)rcp-enhanced-logs/|(^|/)debug-reports/|(^|/)\.trash/|(^|/)\.st(folder|versions)/|(^|/)\.stignore$|(^|/)cursor-state/\.diag-|(^|/)sync-probe\.md$|(^|/)sync-health/|livesync_log'

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'debug-reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$report = Join-Path $reportDir "sync-verify-$ts.txt"
$lines = New-Object System.Collections.Generic.List[string]
function W($s,$c){ $lines.Add(($s -replace '\e\[[0-9;]*m','')); if($c){Write-Host $s -ForegroundColor $c}else{Write-Host $s} }

W "##############################################################################"
W "# VAULT PARITY VERIFY   $ts   (master: $VaultDir)"
W "##############################################################################"
W "# Proves every note on every device is byte-for-byte identical to the master."
W "# IDENTICAL=in sync  LAGGING=device has old version  MISSING=device lacks it  EXTRA=device has unpushed file"
W "# A backgrounded phone/tablet legitimately lags (Android syncs only foregrounded) -- foreground + re-run."
W ""

# ---- master manifest (fast .NET md5) ----
W "Hashing master vault..." Cyan
$md5 = [System.Security.Cryptography.MD5]::Create()
$master = @{}
$vlen = $VaultDir.TrimEnd('\').Length + 1
Get-ChildItem $VaultDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
	$rel = $_.FullName.Substring($vlen).Replace('\','/')
	if ($rel -match $IgnoreRx) { return }
	try { $master[$rel] = [BitConverter]::ToString($md5.ComputeHash([IO.File]::ReadAllBytes($_.FullName))).Replace('-','').ToLower() } catch {}
}
W ("  master: {0} files" -f $master.Count) Gray
W ""

$haveAdb = $null -ne (Get-Command adb -ErrorAction SilentlyContinue)
if (-not $haveAdb) {
	W "adb not installed -- can't compare phone/tablet from here." Yellow
	W "Run this script ON each device's machine, or install platform-tools." Yellow
}

$summary = @()
foreach ($d in $Android) {
	if (-not $haveAdb) { break }
	$serial = "$($d.ip):5555"
	$conn = (& adb connect $serial 2>&1 | Select-Object -Last 1)
	if ($conn -notmatch 'connected') { W ("[$($d.name)] OFFLINE ($serial) -- skipped") Yellow; $summary += [pscustomobject]@{dev=$d.name;state='OFFLINE'}; continue }
	W "Hashing $($d.name) vault (this can take a moment)..." Cyan
	# one shell call: md5sum every file under the vault
	$raw = & adb -s $serial shell "cd '$($d.vault)' && find . -type f 2>/dev/null -exec md5sum {} \;" 2>$null
	$dev = @{}
	foreach ($ln in $raw) {
		if ($ln -match '^([0-9a-f]{32})\s+\.\/(.+)$') {
			$rel = $Matches[2].Trim()
			if ($rel -match $IgnoreRx) { continue }
			$dev[$rel] = $Matches[1].ToLower()
		}
	}
	# diff
	$identical=0; $lagging=@(); $missing=@(); $extra=@()
	foreach ($rel in $master.Keys) {
		if ($dev.ContainsKey($rel)) { if ($dev[$rel] -eq $master[$rel]) { $identical++ } else { $lagging += $rel } }
		else { $missing += $rel }
	}
	foreach ($rel in $dev.Keys) { if (-not $master.ContainsKey($rel)) { $extra += $rel } }
	# SETTLE + RECHECK: cursor-state/*.json change on every scroll, so an instant snapshot can show a
	# volatile file as "lagging" when it is simply mid-replication. Re-hash only the mismatched files
	# after a short settle: anything that converges was transient (counts as in-sync); only files still
	# stuck after settling are a genuine failure.
	$converged = 0
	$candidates = @(@($lagging) + @($missing) + @($extra) | Select-Object -Unique)
	if ($candidates.Count) {
		Start-Sleep -Seconds 8
		$nl=@(); $nm=@(); $nx=@()
		foreach ($rel in $candidates) {
			$mp = Join-Path $VaultDir ($rel -replace '/','\')
			$mh = if (Test-Path $mp) { [BitConverter]::ToString($md5.ComputeHash([IO.File]::ReadAllBytes($mp))).Replace('-','').ToLower() } else { $null }
			$draw = (& adb -s $serial shell "md5sum '$($d.vault)/$rel' 2>/dev/null" 2>$null)
			$dh = if ($draw -match '^([0-9a-f]{32})') { $Matches[1].ToLower() } else { $null }
			if ($mh -and $dh) { if ($mh -eq $dh) { $converged++ } else { $nl += $rel } }
			elseif ($mh) { $nm += $rel }
			elseif ($dh) { $nx += $rel }
			else { $converged++ }
		}
		$identical += $converged
		$lagging = $nl; $missing = $nm; $extra = $nx
	}
	# Split durable NOTES from volatile cursor-state: the green light is about NOTES being identical.
	# Cursor positions are live & eventually-consistent (someone is always mid-scroll) -- whether cursor
	# replication is actually FLOWING is judged by sync-checkup's live probe, not an instant snapshot here.
	$allIssues = @(@($lagging) + @($missing) + @($extra))
	$cursorIssues = @($allIssues | Where-Object { $_ -match '^cursor-state/' })
	$noteIssues   = @($allIssues | Where-Object { $_ -notmatch '^cursor-state/' })
	$perfect = ($noteIssues.Count -eq 0)
	$summary += [pscustomobject]@{dev=$d.name;state=$(if($perfect){'PERFECT'}else{'MISMATCH'});files=$dev.Count;identical=$identical;noteIssues=$noteIssues.Count;cursorIssues=$cursorIssues.Count;lagging=$lagging.Count;missing=$missing.Count;extra=$extra.Count}

	W ""
	W ("===== $($d.name)  (files: $($dev.Count)) =====") Cyan
	W ("  IDENTICAL : $identical") Green
	W ("  LAGGING   : $($lagging.Count)" ) $(if($lagging.Count){'Yellow'}else{'Gray'})
	W ("  MISSING   : $($missing.Count)" ) $(if($missing.Count){'Yellow'}else{'Gray'})
	W ("  EXTRA     : $($extra.Count)"   ) $(if($extra.Count){'Yellow'}else{'Gray'})
	if ($converged) { W ("  (settled: $converged volatile file(s) e.g. cursor positions were mid-sync and converged on recheck -- normal)") Gray }
	if ($lagging.Count) { W "  -- LAGGING (device has an OLD version) --" Yellow; $lagging | Select-Object -First $ShowFiles | ForEach-Object { W "     $_" }; if($lagging.Count -gt $ShowFiles){ W "     ... +$($lagging.Count-$ShowFiles) more" } }
	if ($missing.Count) { W "  -- MISSING (device never pulled it) --" Yellow; $missing | Select-Object -First $ShowFiles | ForEach-Object { W "     $_" }; if($missing.Count -gt $ShowFiles){ W "     ... +$($missing.Count-$ShowFiles) more" } }
	if ($extra.Count)   { W "  -- EXTRA (device has an UNPUSHED file) --" Yellow; $extra | Select-Object -First $ShowFiles | ForEach-Object { W "     $_" }; if($extra.Count -gt $ShowFiles){ W "     ... +$($extra.Count-$ShowFiles) more" } }
	if ($cursorIssues.Count) { W ("  NOTE: $($cursorIssues.Count) of the above are cursor-state/ files (live reading positions, eventually-consistent -- they converge continuously; sync-checkup's probe confirms cursor replication is flowing).") DarkGray }
	if ($perfect -and $cursorIssues.Count) { W "  => NOTES in perfect sync (cursor positions still propagating -- normal)." Green }
	elseif ($perfect) { W "  => PERFECT SYNC with master." Green }
	else { W "  => NOTES out of sync (see note files above) -- this is a real gap." Yellow }
}

W ""
W "==================== VERDICT ===================="
$reachable = $summary | Where-Object { $_.state -ne 'OFFLINE' }
$offline   = $summary | Where-Object { $_.state -eq 'OFFLINE' }
if (-not $haveAdb) {
	W "  Could not compare devices (no adb). Run on each machine to verify it." Yellow
} elseif ($reachable.Count -eq 0) {
	W "  No device was reachable to compare. Foreground/connect them and re-run." Yellow
} elseif (($reachable | Where-Object { $_.state -eq 'MISMATCH' }).Count -eq 0) {
	W "  PERFECT SYNC. Every reachable device has all NOTES byte-for-byte identical to the master." Green
	$stillCursor = @($reachable | Where-Object { $_.cursorIssues -gt 0 })
	if ($stillCursor.Count) { W "  (Cursor positions on $(($stillCursor.dev) -join ', ') are still propagating -- live & eventually-consistent, not a fault; sync-checkup's probe confirms cursor replication is flowing.)" Gray }
	if ($offline) { W "  (Not checked, offline: $(($offline.dev) -join ', ') -- foreground them and re-run.)" Gray }
} else {
	foreach ($s in $reachable) {
		if ($s.state -eq 'MISMATCH') {
			W ("  [$($s.dev)] NOTES out of sync: $($s.noteIssues) note file(s) differ (real gap). Plus $($s.cursorIssues) cursor file(s) still propagating (normal).") Yellow
		}
	}
	W ""
	W "  A NOTE gap is real: the device is backgrounded (Android syncs only foregrounded) or replication" Cyan
	W "  stalled. FIX: foreground Obsidian on that device for ~15s, then re-run. If it persists:" Cyan
	W "  pwsh scripts\sync-kick.ps1 -All   then re-run." Cyan
	if ($offline) { W "  (Offline, not checked: $(($offline.dev) -join ', '))" Gray }
}
W ""
W "## FOR COPILOT / CODE CLOUD"
W "  Paste this file and ask: 'This is a byte-level vault parity check across my synced devices."
W "  Which device is out of sync, in which direction (pull vs push), and what's the fix?'"

[System.IO.File]::WriteAllText($report, ($lines -join "`r`n"), $enc)
Write-Host ""
Write-Host "==> Parity report saved: $report" -ForegroundColor Green
