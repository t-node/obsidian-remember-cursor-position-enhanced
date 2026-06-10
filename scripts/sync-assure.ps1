<#
.SYNOPSIS
  THE GREEN LIGHT. One command for full assurance that every device is in perfect sync.
  It WAKES all devices, then proves: same node, replication flowing, every note byte-identical.
  Prints one verdict: PERFECT SYNC (all green) or NOT YET (with exactly what's wrong).

.DESCRIPTION
  Runs three phases and combines them into a single PASS/FAIL:
    PHASE 1  WAKE      - reconnect adb to every phone/tablet and bring Obsidian to the foreground,
                         then warm up so each device actively replicates (Android only syncs foregrounded).
    PHASE 2  PIPELINE  - runs sync-checkup.ps1: connections (CouchDB + Tailscale), every device on the
                         same node + in reliable mode, and a LIVE marker that must reach every device.
    PHASE 3  CONTENT   - runs sync-verify.ps1: hashes the whole vault on every device and proves it is
                         byte-for-byte identical to the master (0 lagging / missing / extra).

  PASS = no CRITICAL/HIGH/MED in the pipeline AND content parity is PERFECT on every reachable device.
  Re-run it after foregrounding any sleeping device to re-certify. Saves one combined report for Copilot.

.PARAMETER NoWake       Skip waking devices (assume they're already foregrounded).
.PARAMETER Warmup       Seconds to let woken devices sync before testing (default 25).

.EXAMPLE
  pwsh scripts\sync-assure.ps1
#>
[CmdletBinding()]
param(
	[switch]$NoWake,
	[int]$Warmup = 25
)
. "$PSScriptRoot\_sync-config.ps1"
$ErrorActionPreference = 'Continue'
$Android = $SyncConfig.Devices
$enc = New-Object System.Text.UTF8Encoding($false)
$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'debug-reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$report = Join-Path $reportDir "sync-assure-$ts.txt"
$lines = New-Object System.Collections.Generic.List[string]
function W($s,$c){ $lines.Add(($s -replace '\e\[[0-9;]*m','')); if($c){Write-Host $s -ForegroundColor $c}else{Write-Host $s} }
$haveAdb = $null -ne (Get-Command adb -ErrorAction SilentlyContinue)

W "##############################################################################"
W "#                   SYNC ASSURANCE (full green-light check)"
W "#                   $ts   master: $env:COMPUTERNAME"
W "##############################################################################"
W ""

# ---------------- PHASE 1: WAKE ----------------
W "=== PHASE 1: WAKE ALL DEVICES ===" Cyan
$woke = @()
if ($NoWake) { W "  (skipped: -NoWake)" DarkGray }
elseif (-not $haveAdb) { W "  adb not installed -- cannot wake phone/tablet from here." Yellow }
else {
	foreach ($d in $Android) {
		$serial = "$($d.ip):5555"
		$conn = (& adb connect $serial 2>&1 | Select-Object -Last 1)
		if ($conn -match 'connected') {
			& adb -s $serial shell "monkey -p md.obsidian -c android.intent.category.LAUNCHER 1" 2>$null | Out-Null
			W ("  {0,-7}: foregrounded Obsidian (now actively syncing)" -f $d.name) Green
			$woke += $d.name
		} else {
			W ("  {0,-7}: OFFLINE ({1}) -- can't wake. If rebooted: USB once + adb-net.ps1 -Enable" -f $d.name,$serial) Yellow
		}
	}
	if ($woke.Count) { W ("  warming up ${Warmup}s so woken devices replicate..." ) Gray; Start-Sleep -Seconds $Warmup }
}
W ""

# ---------------- PHASE 2: PIPELINE (sync-checkup) ----------------
W "=== PHASE 2: PIPELINE (connections + same node + live replication) ===" Cyan
$checkupOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sync-checkup.ps1') 2>&1 | ForEach-Object { "$_" }
$checkupOut | ForEach-Object { $lines.Add($_) }   # fold full checkup into the combined report (not re-printed)
$crit = @($checkupOut | Where-Object { $_ -match '\[CRITICAL\]' })
$high = @($checkupOut | Where-Object { $_ -match '\[HIGH\]' })
$med  = @($checkupOut | Where-Object { $_ -match '\[MED\]' })
$probeHits = @($checkupOut | Where-Object { $_ -match 'RECEIVED marker at' })
$pipelinePass = ($crit.Count -eq 0 -and $high.Count -eq 0 -and $med.Count -eq 0)
W ("  CouchDB/Tailscale/config/live-probe: {0}" -f $(if($pipelinePass){'PASS'}else{'FAIL'})) $(if($pipelinePass){'Green'}else{'Red'})
$probeHits | ForEach-Object { W "    $($_.Trim())" Green }
if (-not $pipelinePass) {
	($crit + $high + $med) | ForEach-Object { W "    $($_.Trim())" Yellow }
}
W ""

# ---------------- PHASE 3: CONTENT PARITY (sync-verify) ----------------
W "=== PHASE 3: CONTENT (every note byte-identical on every device) ===" Cyan
$verifyOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sync-verify.ps1') 2>&1 | ForEach-Object { "$_" }
$verifyOut | ForEach-Object { $lines.Add($_) }
$contentPass = [bool](@($verifyOut | Where-Object { $_ -match 'PERFECT SYNC\. Every reachable device' }).Count)
@($verifyOut | Where-Object { $_ -match '=> PERFECT SYNC with master|NOT in sync|IDENTICAL :' }) | ForEach-Object { W "    $($_.Trim())" $(if($_ -match 'NOT in sync'){'Yellow'}else{'Gray'}) }
W ("  whole-vault parity: {0}" -f $(if($contentPass){'PASS'}else{'FAIL'})) $(if($contentPass){'Green'}else{'Red'})
W ""

# ---------------- COMBINED VERDICT ----------------
W "##############################################################################"
if ($pipelinePass -and $contentPass) {
	W "#   RESULT:  PERFECT SYNC  -- ALL DEVICES GREEN" Green
	W "#   Same CouchDB node, replication flowing, every note byte-for-byte identical everywhere." Green
	$off = @($Android | Where-Object { $_.name -notin $woke -and -not $NoWake }) | ForEach-Object { $_.name }
} else {
	W "#   RESULT:  NOT YET IN PERFECT SYNC" Red
	if (-not $pipelinePass) { W "#   - PIPELINE failed: see the [CRITICAL]/[HIGH]/[MED] lines above." Red }
	if (-not $contentPass)  { W "#   - CONTENT parity failed: a device has lagging/missing/extra files (see PHASE 3)." Red }
	W "#   FIX: foreground the failing device(s) for ~15s, then re-run this script." Cyan
	W "#        If it persists:  pwsh scripts\sync-kick.ps1 -All   then re-run." Cyan
}
W "##############################################################################"
# note any device we couldn't reach/wake (not certified)
$unreached = @($Android | Where-Object { $_.name -notin $woke }) | ForEach-Object { $_.name }
if (-not $NoWake -and $unreached.Count) { W "  NOTE: not certified (offline/unreachable): $($unreached -join ', '). Wake them and re-run." Yellow }
W "  NOTE: the 2nd laptop ('Notes') can't be tested from here -- run this script ON that laptop too." Yellow
W ""
W "  Full pipeline + parity detail is in this report. Paste it into Copilot if you want a second opinion."

[System.IO.File]::WriteAllText($report, ($lines -join "`r`n"), $enc)
Write-Host ""
Write-Host "==> Assurance report saved: $report" -ForegroundColor Green
