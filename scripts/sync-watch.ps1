<#
.SYNOPSIS
  LIVE PROPAGATION MONITOR. The real test for "I type on one device, does it show up on ALL the others
  within a few seconds?" Watches a test note across every reachable device and times how fast an edit on
  ANY device converges to the rest -- and flags exactly which device missed it (and whether it was asleep).

.DESCRIPTION
  Run it, then in Obsidian open the test note (sync-test.md) on any FOREGROUNDED device and type something.
  The monitor detects the change and reports, live, how many seconds until every reachable device matches.

  HARD TRUTH it makes visible: a backgrounded phone/tablet CANNOT converge within seconds (Android pauses
  sync off-screen) -- it catches up the moment you foreground it. So "100% within seconds to ALL devices"
  only holds while every device is awake + on-screen. This tool proves the latency for the ACTIVE devices
  and pinpoints which device lagged + that it was asleep -- separating a real stall from normal eventual
  consistency.

  Watches this master + adb-reachable phone/tablet. The 2nd laptop has no adb -> run this ON it to include it.

.PARAMETER Minutes       How long to watch (default 5).
.PARAMETER StuckSeconds  Flag a device as stuck if an edit hasn't reached it within this (default 75).
.PARAMETER TestNote      Note filename in the vault root to watch (default sync-test.md).

.EXAMPLE
  pwsh scripts\sync-watch.ps1
  # then edit sync-test.md in Obsidian on any device and watch it ripple to the others.
#>
[CmdletBinding()]
param([int]$Minutes = 5, [int]$StuckSeconds = 75, [string]$TestNote = 'sync-test.md', [string]$VaultDir)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_sync-config.ps1"
$enc = New-Object System.Text.UTF8Encoding($false)
$haveAdb = $null -ne (Get-Command adb -ErrorAction SilentlyContinue)
$masterFile = Join-Path $VaultDir $TestNote

function NowStr { (Get-Date).ToString('HH:mm:ss') }
function HashStr($s) { if (-not $s) { return $null }; $md5=[System.Security.Cryptography.MD5]::Create(); ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-','')).Substring(0,8).ToLower() }

# seed the test note if missing
if (-not (Test-Path $masterFile)) {
	[System.IO.File]::WriteAllText($masterFile, "# Sync test`n`nEdit this line on any device and watch sync-watch report it: 0`n", $enc)
	Write-Host "Created $masterFile -- it will sync to all devices. Open it in Obsidian to edit." -ForegroundColor Cyan
}

# connect adb devices once
$targets = @()
if ($haveAdb) {
	foreach ($d in $SyncConfig.Devices) {
		$serial = "$($d.ip):5555"
		if ((& adb connect $serial 2>&1 | Select-Object -Last 1) -match 'connected') { $targets += @{ name=$d.name; serial=$serial; path="$($d.vault)/$TestNote" } }
		else { Write-Host "  $($d.name) offline ($serial) -- not watched" -ForegroundColor Yellow }
	}
} else { Write-Host "  adb not installed -- only this master is watched." -ForegroundColor Yellow }

function Get-Hashes {
	$h = [ordered]@{}
	if (Test-Path $masterFile) { try { $h['master'] = HashStr ([IO.File]::ReadAllText($masterFile)) } catch {} }
	foreach ($t in $targets) {
		$c = (& adb -s $t.serial shell "cat '$($t.path)' 2>/dev/null" 2>$null) -join "`n"
		$h[$t.name] = if ($c) { HashStr $c } else { 'absent' }
	}
	return $h
}

Write-Host "`n=== LIVE PROPAGATION MONITOR ($Minutes min) ===" -ForegroundColor Cyan
Write-Host "Watching '$TestNote' on: $(@('master') + ($targets.name) -join ', ')" -ForegroundColor Gray
Write-Host "Now: open '$TestNote' in Obsidian on any FOREGROUNDED device, type, and save. Watch below." -ForegroundColor Cyan
Write-Host "(Ctrl+C to stop early. A backgrounded device will show as MISSED until you foreground it.)`n" -ForegroundColor DarkGray

$prev = Get-Hashes
$converged = (@($prev.Values | Sort-Object -Unique).Count -le 1)
$epStart = $null; $epSrc = $null; $stuckWarned = $false
$end = (Get-Date).AddMinutes($Minutes)
$lat = New-Object System.Collections.Generic.List[double]
$episodes = 0; $missed = 0

while ((Get-Date) -lt $end) {
	Start-Sleep -Seconds 2
	$cur = Get-Hashes
	$distinct = @($cur.Values | Sort-Object -Unique)
	if ($distinct.Count -le 1) {
		if (-not $converged) {
			$secs = [math]::Round(((Get-Date) - $epStart).TotalSeconds)
			$lat.Add($secs); $episodes++
			Write-Host ("[{0}] CONVERGED in {1}s -- edit from '{2}' reached ALL {3} device(s)." -f (NowStr),$secs,$epSrc,$cur.Count) -ForegroundColor Green
			$converged = $true; $epStart = $null; $stuckWarned = $false
		}
	} else {
		if ($converged) {
			$epStart = Get-Date; $converged = $false; $stuckWarned = $false
			$changed = @($cur.Keys | Where-Object { $cur[$_] -ne $prev[$_] })
			$epSrc = if ($changed) { $changed -join '+' } else { 'unknown' }
			Write-Host ("[{0}] EDIT detected (source: {1}) -- watching propagation..." -f (NowStr),$epSrc) -ForegroundColor Yellow
		} else {
			if (-not $epStart) { $epStart = Get-Date; $epSrc = 'startup' }   # was already diverging when watch began
			$elapsed = [math]::Round(((Get-Date) - $epStart).TotalSeconds)
			if ($elapsed -ge $StuckSeconds -and -not $stuckWarned) {
				# whoever differs from master is behind
				$ref = $cur['master']
				$behind = @($cur.Keys | Where-Object { $_ -ne 'master' -and $cur[$_] -ne $ref })
				if (-not $behind) { $behind = @($cur.Keys | Where-Object { $cur[$_] -ne ($cur.Values | Group-Object | Sort-Object Count -Desc | Select-Object -First 1).Name }) }
				Write-Host ("[{0}] MISSED -- after {1}s these still differ: {2}. Almost always backgrounded/asleep -> foreground them; if awake+foregrounded and still stuck, it's a real stall (run sync.ps1)." -f (NowStr),$elapsed,($behind -join ', ')) -ForegroundColor Red
				$missed++; $stuckWarned = $true
			}
		}
	}
	$prev = $cur
}

Write-Host "`n=== SUMMARY ===" -ForegroundColor Cyan
if ($episodes -eq 0 -and $missed -eq 0) { Write-Host "No edits seen. Edit '$TestNote' in Obsidian on a device while this runs." -ForegroundColor Yellow }
else {
	Write-Host ("Edits that converged to ALL active devices: {0}" -f $episodes) -ForegroundColor Green
	if ($lat.Count) { Write-Host ("  propagation latency: min {0}s / avg {1}s / max {2}s" -f ($lat | Measure-Object -Minimum).Minimum, [math]::Round(($lat | Measure-Object -Average).Average,1), ($lat | Measure-Object -Maximum).Maximum) }
	if ($missed) { Write-Host ("Edits that a device MISSED within ${StuckSeconds}s: {0} (a backgrounded device -- foreground it and it converges)" -f $missed) -ForegroundColor Yellow }
}
Write-Host "Reliability rule: every AWAKE+FOREGROUNDED device should converge in a few seconds. A miss = that device was asleep, not data loss." -ForegroundColor Gray
