<#
.SYNOPSIS
  Run this ON a Windows laptop that won't sync. It fixes the config that makes a new device
  flood its own debug log, sets reliable sync mode, clears the flood, and tests CouchDB.

.DESCRIPTION
  Fixes the exact problem seen in the LiveSync log ("STORAGE -> DB rcp-enhanced-logs/...log"
  every 2 seconds): RCP-E logging was on AND LiveSync wasn't ignoring the log folder, so the
  pipe was 100% busy syncing the debug log instead of your cursor positions.

  It does NOT touch your CouchDB connection / encryption - only the sync-behaviour settings.
  Obsidian must be closed; the script closes it for you, then you reopen + Fetch.

.PARAMETER VaultDir
  Your Obsidian vault folder on THIS laptop (the one containing the .obsidian folder).
  If omitted, the script looks in the current folder and common locations.

.EXAMPLE
  pwsh scripts\fix-this-laptop.ps1 -VaultDir "C:\Users\you\Documents\Notes"
  pwsh scripts\fix-this-laptop.ps1        # if you run it from inside the vault folder
#>
[CmdletBinding()]
param(
	[string]$VaultDir,
	[string]$CouchUrl,
	[string]$DbName,
	[string]$CouchUser,
	[string]$CouchPass
)
. "$PSScriptRoot\_sync-config.ps1"
# This helper runs ON a remote laptop, so reach CouchDB via the Tailscale URL (not local 127.0.0.1).
if (-not $PSBoundParameters.ContainsKey('CouchUrl')) { $CouchUrl = $SyncConfig.TailscaleUrl }
$ErrorActionPreference = 'Stop'
$enc = New-Object System.Text.UTF8Encoding($false)   # UTF-8 NO BOM (Obsidian needs this)

function Find-Vault {
	if ($VaultDir) { return $VaultDir }
	if (Test-Path ".\.obsidian\plugins\obsidian-livesync\data.json") { return (Get-Location).Path }
	Write-Host "Searching common locations for your vault..." -ForegroundColor Cyan
	$roots = @("$env:USERPROFILE\Documents", "$env:USERPROFILE\Desktop", "$env:USERPROFILE", "D:\")
	foreach ($r in $roots) {
		if (-not (Test-Path $r)) { continue }
		$hit = Get-ChildItem -Path $r -Recurse -Depth 5 -Filter 'obsidian-livesync' -Directory -ErrorAction SilentlyContinue |
			Where-Object { Test-Path "$($_.FullName)\data.json" } | Select-Object -First 1
		if ($hit) { return (Split-Path (Split-Path (Split-Path $hit.FullName))) }  # ...\.obsidian\plugins\X -> vault
	}
	return $null
}

function Set-Prop($obj, $name, $val) {
	if ($obj.PSObject.Properties[$name]) { $obj.$name = $val }
	else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $val -Force }
}

$vault = Find-Vault
if (-not $vault) {
	Write-Host "Could not find your vault. Re-run with:  -VaultDir `"C:\path\to\your\vault`"" -ForegroundColor Red
	exit 1
}
Write-Host "Vault: $vault" -ForegroundColor Green
$lsPath  = Join-Path $vault ".obsidian\plugins\obsidian-livesync\data.json"
$rcpPath = Join-Path $vault ".obsidian\plugins\remember-cursor-position-enhanced\data.json"
if (-not (Test-Path $lsPath)) { Write-Host "No LiveSync config at $lsPath - is this the right vault?" -ForegroundColor Red; exit 1 }

# 1. Close Obsidian so edits stick
$obs = Get-Process Obsidian -ErrorAction SilentlyContinue
if ($obs) { Write-Host "Closing Obsidian..." -ForegroundColor Cyan; $obs | Stop-Process -Force; Start-Sleep -Seconds 2 }

# 2. Patch LiveSync: reliable mode + ignore the log folder (connection/encryption untouched)
Write-Host "Patching LiveSync config..." -ForegroundColor Cyan
$ls = Get-Content $lsPath -Raw | ConvertFrom-Json
Set-Prop $ls 'liveSync' $false
Set-Prop $ls 'syncOnStart' $true
Set-Prop $ls 'syncOnSave' $true
Set-Prop $ls 'syncOnFileOpen' $true
Set-Prop $ls 'periodicReplication' $true
Set-Prop $ls 'periodicReplicationInterval' 10
Set-Prop $ls 'useHistory' $false
Set-Prop $ls 'writeLogToTheFile' $false
Set-Prop $ls 'skipOlderFilesOnSync' $false
Set-Prop $ls 'syncIgnoreRegEx' '^rcp-enhanced-logs/|^cursor-state/\.diag-|^livesync_log'
[System.IO.File]::WriteAllText($lsPath, ($ls | ConvertTo-Json -Depth 40), $enc)
Write-Host "  LiveSync: liveSync=off, periodic=10s, onSave/onOpen=on, history=off, log folder ignored" -ForegroundColor Green

# 3. Patch RCP-E: stop writing debug logs (the source of the flood)
if (Test-Path $rcpPath) {
	$rcp = Get-Content $rcpPath -Raw | ConvertFrom-Json
	Set-Prop $rcp 'logToFile' $false
	Set-Prop $rcp 'debugLogging' $false
	Set-Prop $rcp 'saveDebounceMs' 1500
	[System.IO.File]::WriteAllText($rcpPath, ($rcp | ConvertTo-Json -Depth 20), $enc)
	Write-Host "  RCP-E: logToFile=off, debugLogging=off, saveDebounceMs=1500" -ForegroundColor Green
} else { Write-Host "  (RCP-E config not found - enable the plugin, then re-run)" -ForegroundColor Yellow }

# 4. Delete the flood: existing logs that were being re-pushed
$logDir = Join-Path $vault 'rcp-enhanced-logs'
if (Test-Path $logDir) { Remove-Item $logDir -Recurse -Force; Write-Host "  Deleted rcp-enhanced-logs\ (the flooded log)" -ForegroundColor Green }
Get-ChildItem (Join-Path $vault 'livesync_log_*.md') -ErrorAction SilentlyContinue | Remove-Item -Force

# 5. Test CouchDB reachability from THIS laptop
Write-Host "`nTesting CouchDB connection from this laptop..." -ForegroundColor Cyan
$h = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${CouchUser}:${CouchPass}")))" }
try {
	$db = Invoke-RestMethod "$CouchUrl/$DbName" -Headers $h -TimeoutSec 12
	Write-Host "  CONNECTION OK -> reached '$DbName' ($($db.doc_count) docs). Tailscale + auth work." -ForegroundColor Green
} catch {
	$msg = $_.Exception.Message
	Write-Host "  CONNECTION FAILED: $msg" -ForegroundColor Red
	if ($msg -match 'timed out|No such host|actively refused|remote name') {
		Write-Host "    -> Tailscale isn't reaching the server. Open the Tailscale app, ensure it's Connected." -ForegroundColor Yellow
	} elseif ($msg -match '401') {
		Write-Host "    -> Reached CouchDB but wrong credentials (this is just the test; your encrypted config may still be fine)." -ForegroundColor Yellow
	}
}

Write-Host "`nDONE. Now:" -ForegroundColor Green
Write-Host "  1. Reopen Obsidian on this laptop." -ForegroundColor Green
Write-Host "  2. LiveSync -> run 'Fetch everything from the remote' (first sync pulls the vault)." -ForegroundColor Green
Write-Host "  3. Open a note and scroll - it should now sync within a few seconds." -ForegroundColor Green
Write-Host "  (It will NOT flood the log anymore.)" -ForegroundColor Green
