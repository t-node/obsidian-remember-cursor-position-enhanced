<#
.SYNOPSIS
  THE "sync is stuck, fix it" BUTTON. Run this anytime cursor positions stop syncing.

.DESCRIPTION
  Like rebooting a machine that's misbehaving — but for your sync. Over Tailscale (no USB) it:
    1. Reconnects adb to every Android device.
    2. Re-asserts the correct sync settings (liveSync + syncOnSave + 30s periodic, logs off,
       history off) in case anything drifted.
    3. Restarts Obsidian on each phone/tablet so replication re-establishes (the proven cure
       for an idle/stuck LiveSync connection) and brings it to the foreground.
    4. Optionally restarts Obsidian on this laptop too (-All).
    5. Waits, then prints the cross-device health check so you can SEE it converge.

  This does NOT touch CouchDB or your notes — it only wakes up the sync. For deep corruption
  (chunk errors / bloat) use scripts/sync-reset.ps1 instead (see SYNC-RUNBOOK.md).

.PARAMETER All   Also restart Obsidian on this laptop (closes + reopens it).
.PARAMETER NoRestart   Only re-assert config + reconnect, don't restart the apps.

.EXAMPLE
  pwsh scripts/sync-kick.ps1          # fix the phone + tablet, verify
  pwsh scripts/sync-kick.ps1 -All     # also restart the laptop's Obsidian
#>
[CmdletBinding()]
param([switch]$All, [switch]$NoRestart)
. "$PSScriptRoot\_sync-config.ps1"

$ErrorActionPreference = 'Continue'

# Known Android devices: name / Tailscale IP / vault path. Add new devices here.
$Devices = $SyncConfig.Devices
$LaptopVault = $SyncConfig.VaultDir
$root = Split-Path $PSScriptRoot -Parent

# Re-assert the known-good sync settings on a raw data.json string (idempotent, format-safe).
function Set-SyncFields([string]$raw) {
	# RELIABLE (batch) mode: liveSync OFF so the periodic fallback actually runs. The live
	# connection dies over Tailscale and, while on, suppresses periodic — that was the recurring
	# freeze. Instead: push on save, pull on note-open, and a 10s timer. Short reconnecting
	# replications never get stuck the way one long-lived connection does.
	$raw = $raw -replace '"liveSync":\s*(true|false)', '"liveSync": false'
	$raw = $raw -replace '"syncOnStart":\s*(true|false)', '"syncOnStart": true'
	$raw = $raw -replace '"syncOnSave":\s*(true|false)', '"syncOnSave": true'
	$raw = $raw -replace '"syncOnFileOpen":\s*(true|false)', '"syncOnFileOpen": true'
	$raw = $raw -replace '"periodicReplication":\s*(true|false)', '"periodicReplication": true'
	$raw = $raw -replace '"periodicReplicationInterval":\s*\d+', '"periodicReplicationInterval": 10'
	$raw = $raw -replace '"writeLogToTheFile":\s*(true|false)', '"writeLogToTheFile": false'
	$raw = $raw -replace '"useHistory":\s*(true|false)', '"useHistory": false'
	$raw = $raw -replace '"skipOlderFilesOnSync":\s*(true|false)', '"skipOlderFilesOnSync": false'
	return $raw
}

Write-Host "=== SYNC KICK ===" -ForegroundColor Cyan

foreach ($d in $Devices) {
	$serial = "$($d.ip):5555"
	$r = (& adb connect $serial 2>&1 | Select-Object -Last 1)
	if ($r -notmatch 'connected') {
		Write-Host ("  {0,-7} OFFLINE ({1}:5555) - {2}" -f $d.name, $d.ip, $r) -ForegroundColor Yellow
		Write-Host "          (if it was rebooted: USB once + 'scripts/adb-net.ps1 -Enable')" -ForegroundColor DarkGray
		continue
	}
	$rp = "$($d.vault)/.obsidian/plugins/obsidian-livesync/data.json"
	# stop app so the config edit sticks
	& adb -s $serial shell "am force-stop md.obsidian" 2>$null | Out-Null
	Start-Sleep -Milliseconds 600
	# re-assert config (byte-exact, no BOM)
	$raw = (& adb -s $serial shell "cat '$rp'" 2>$null) -join "`n"
	if ($raw -match '"isConfigured":\s*true') {
		$new = Set-SyncFields $raw
		$tmp = New-TemporaryFile
		[System.IO.File]::WriteAllText($tmp, $new, (New-Object System.Text.UTF8Encoding($false)))
		& adb -s $serial push $tmp $rp 2>$null | Out-Null
		Remove-Item $tmp -Force -ErrorAction SilentlyContinue
		Write-Host ("  {0,-7} config re-asserted" -f $d.name) -ForegroundColor Green
	} else {
		Write-Host ("  {0,-7} WARNING: not configured - skipped config edit" -f $d.name) -ForegroundColor Yellow
	}
	# restart Obsidian (resumes replication via syncOnStart) + foreground
	if (-not $NoRestart) {
		& adb -s $serial shell "monkey -p md.obsidian -c android.intent.category.LAUNCHER 1" 2>$null | Out-Null
		Write-Host ("  {0,-7} Obsidian restarted (sync resuming)" -f $d.name) -ForegroundColor Green
	}
}

# Laptop
$lap = "$LaptopVault\.obsidian\plugins\obsidian-livesync\data.json"
if ($All) {
	$proc = Get-Process Obsidian -ErrorAction SilentlyContinue | Select-Object -First 1
	$exe = if ($proc) { $proc.Path } else { "$env:LOCALAPPDATA\Obsidian\Obsidian.exe" }
	Get-Process Obsidian -ErrorAction SilentlyContinue | Stop-Process -Force
	Start-Sleep -Seconds 2
	if (Test-Path $lap) {
		$new = Set-SyncFields ([System.IO.File]::ReadAllText($lap))
		[System.IO.File]::WriteAllText($lap, $new, (New-Object System.Text.UTF8Encoding($false)))
	}
	if (Test-Path $exe) { Start-Process $exe; Write-Host "  laptop  Obsidian restarted + config re-asserted" -ForegroundColor Green }
	else { Write-Host "  laptop  reopen Obsidian manually (exe not found)" -ForegroundColor Yellow }
} else {
	# don't kill the laptop app; just make sure its config is right for next start
	if (Test-Path $lap) {
		$cur = [System.IO.File]::ReadAllText($lap)
		if ($cur -match '"syncOnSave":\s*false' -or $cur -match '"periodicReplication":\s*false') {
			Write-Host "  laptop  config drifted - run with -All to fix, or toggle in LiveSync settings" -ForegroundColor Yellow
		} else {
			Write-Host "  laptop  config OK (left running)" -ForegroundColor Green
		}
	}
}

Write-Host "`nWaiting 25s for replication to resume..." -ForegroundColor Cyan
Start-Sleep -Seconds 25
Write-Host "`n=== Health check ===" -ForegroundColor Cyan
& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sync-reset.ps1') -Action doctor
Write-Host "`nIf any file still shows DIFF: open that device's Obsidian and look at a note for a few" -ForegroundColor DarkGray
Write-Host "seconds (mobile only syncs in the foreground), then re-run the health check." -ForegroundColor DarkGray
