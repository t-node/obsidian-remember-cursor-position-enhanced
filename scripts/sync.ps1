<#
.SYNOPSIS
  THE ONE RING. Run this. Paste the printed file into Claude / Copilot. Done.
  It runs the complete 360 capture (every check, every device, both directions) and writes ONE file
  whose FIRST lines are a plain verdict: "ALL IN SYNC" or the exact issue(s) + fix.

.DESCRIPTION
  This is the only script you need to remember. It calls sync-360.ps1 (which itself runs the full
  assurance + bidirectional + conflict + skew + storage checks), captures everything, and prepends a
  TL;DR so a human or an AI sees the answer instantly without scrolling.

  Output: debug-reports\SYNC-STATUS-<time>.txt  -> paste the whole thing to Claude/Copilot.

.PARAMETER Minutes  Soak for N minutes to catch intermittent "after a few days" drops (optional).

.EXAMPLE
  pwsh scripts\sync.ps1
  pwsh scripts\sync.ps1 -Minutes 10
#>
[CmdletBinding()]
param([int]$Minutes = 0)
$ErrorActionPreference = 'Continue'
$enc = New-Object System.Text.UTF8Encoding($false)
$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'debug-reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$out = Join-Path $reportDir "SYNC-STATUS-$ts.txt"

Write-Host "Running the full sync check (this takes a few minutes)..." -ForegroundColor Cyan

# Run the deepest capture; capture everything it prints (it logs to console + its own file).
$args360 = @('-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'sync-360.ps1'))
if ($Minutes -gt 0) { $args360 += @('-Minutes',$Minutes) }
$full = & powershell @args360 2>&1 | ForEach-Object { $s = "$_"; Write-Host $s; $s }

# ---- Build the TL;DR from sync-360's verdict ----
$greenLine = @($full | Where-Object { $_ -match 'RESULT:\s*PERFECT SYNC|RESULT:\s*NOT YET' }) | Select-Object -First 1
$issueLines = @($full | Where-Object { $_ -match '^\#\s+\[(CRITICAL|HIGH|MED|LOW|INFO)\]|^\#\s+FIX:' } | ForEach-Object { ($_ -replace '^\#\s*','').TrimEnd() })

# Three honest tiers: GREEN (nothing), AMBER (only soft items: foreground a device / minor cleanup),
# RED (a real connection/config/conflict failure).
$hard = @($issueLines | Where-Object { $_ -match '^\[(CRITICAL|HIGH)\]' }).Count
$soft = @($issueLines | Where-Object { $_ -match '^\[(MED|LOW|INFO)\]' }).Count
$tier = if ($hard) { 'RED' } elseif ($soft) { 'AMBER' } else { 'GREEN' }

$tl = New-Object System.Collections.Generic.List[string]
$tl.Add("##############################################################################")
$tl.Add("#                    SYNC STATUS  -  $ts")
$tl.Add("##############################################################################")
if ($tier -eq 'GREEN') {
	$tl.Add("VERDICT:  ALL IN SYNC  -- no issues found.")
	$tl.Add("Every device is on the same CouchDB node, notes are byte-identical, replication flows both")
	$tl.Add("ways, no real conflicts, clocks aligned, storage healthy.")
} elseif ($tier -eq 'AMBER') {
	$tl.Add("VERDICT:  MOSTLY IN SYNC  -- core sync is healthy; only soft items below.")
	$tl.Add("(Usually: a phone/tablet is backgrounded/locked so it isn't pulling this instant -- wake it --")
	$tl.Add(" and/or a cosmetic cleanup. Your NOTES are in sync. No real conflicts or connection failures.)")
	$tl.Add("")
	$issueLines | ForEach-Object { $tl.Add("  $_") }
} else {
	$tl.Add("VERDICT:  ISSUES FOUND  -- a real connection/config/conflict problem. Details below.")
	$tl.Add("")
	$issueLines | ForEach-Object { $tl.Add("  $_") }
}
$tl.Add("")
if ($greenLine) { $tl.Add("Green-light line: " + ($greenLine -replace '^\s*#?\s*','').Trim()) }
$tl.Add("")
$tl.Add("## HOW TO USE THIS FILE")
$tl.Add("  Paste this ENTIRE file to Claude or Copilot and ask:")
$tl.Add("  'This is my Obsidian cursor-sync status dump. Is everything in sync? If not, what's the exact")
$tl.Add("   issue and the fix?' The full system context + all evidence is in the sections below.")
$tl.Add("")
$tl.Add("==============================================================================")
$tl.Add("  FULL CAPTURE BELOW")
$tl.Add("==============================================================================")
$tl.Add("")

[System.IO.File]::WriteAllText($out, (($tl + $full) -join "`r`n"), $enc)

Write-Host ""
Write-Host "##############################################################################" -ForegroundColor Cyan
switch ($tier) {
	'GREEN' { Write-Host "  ALL IN SYNC -- no issues found." -ForegroundColor Green }
	'AMBER' { Write-Host "  MOSTLY IN SYNC -- core healthy; soft items only (see top of report):" -ForegroundColor Yellow
		$issueLines | Where-Object { $_ -match '^\[(MED|LOW|INFO)\]' } | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow } }
	'RED'   { Write-Host "  ISSUES FOUND -- real problem (see top of report):" -ForegroundColor Red
		$issueLines | Where-Object { $_ -match '^\[(CRITICAL|HIGH)\]' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Red } }
}
Write-Host "##############################################################################" -ForegroundColor Cyan
Write-Host ""
Write-Host "==> ONE FILE TO PASTE: $out" -ForegroundColor Green
