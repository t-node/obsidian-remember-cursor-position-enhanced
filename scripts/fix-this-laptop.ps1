<#
.SYNOPSIS
  Run this ON a Windows laptop that won't sync. It sets reliable sync mode, stops the debug-log flood,
  checks Tailscale, and RESTARTS Obsidian so it reconnects and pulls immediately. One command -> syncing.

.DESCRIPTION
  The fix for "laptop is open but gets no updates": its LiveSync connection died and there was no periodic
  fallback to recover. This patches the local config to reliable mode (liveSync OFF + periodic 10s +
  syncOnStart/Save/FileOpen ON), clears the log flood, verifies Tailscale can reach CouchDB, then closes
  and reopens Obsidian so syncOnStart fires and it pulls the latest.

  SELF-CONTAINED: needs no repo and no sync.config.ps1 -- just copy THIS one file to the laptop and run it.
  It does NOT touch your CouchDB connection/encryption, only the sync-behaviour settings.

.PARAMETER VaultDir   Your vault folder (the one with the .obsidian folder). Auto-detected if omitted.
.PARAMETER CouchUrl   Optional: your Tailscale CouchDB URL, to test reachability (e.g. https://host.tailnet.ts.net).
.PARAMETER NoRestart  Patch + test only; don't restart Obsidian.

.EXAMPLE
  pwsh fix-this-laptop.ps1
  pwsh fix-this-laptop.ps1 -VaultDir "C:\Users\you\Documents\Notes" -CouchUrl https://YOUR-HOST.YOUR-TAILNET.ts.net
#>
[CmdletBinding()]
param(
	[string]$VaultDir,
	[string]$CouchUrl,
	[string]$DbName = 'obsidian-vault',
	[switch]$NoRestart
)
$ErrorActionPreference = 'Stop'
$enc = New-Object System.Text.UTF8Encoding($false)   # UTF-8 NO BOM (Obsidian needs this)

# Optional: pull CouchUrl from a local sync.config.ps1 if present (not required).
if (-not $CouchUrl) {
	$cfg = Join-Path $PSScriptRoot 'sync.config.ps1'
	if (Test-Path $cfg) { try { . $cfg; if ($SyncConfig.TailscaleUrl) { $CouchUrl = $SyncConfig.TailscaleUrl }; if ($SyncConfig.DbName) { $DbName = $SyncConfig.DbName } } catch {} }
}

function Find-Vault {
	if ($VaultDir) { return $VaultDir }
	if (Test-Path ".\.obsidian\plugins\obsidian-livesync\data.json") { return (Get-Location).Path }
	Write-Host "Searching common locations for your vault..." -ForegroundColor Cyan
	$roots = @("$env:USERPROFILE\Documents", "$env:USERPROFILE\Desktop", "$env:USERPROFILE", "$env:USERPROFILE\OneDrive\Documents", "D:\")
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
if (-not $vault) { Write-Host "Could not find your vault. Re-run with:  -VaultDir `"C:\path\to\your\vault`"" -ForegroundColor Red; exit 1 }
Write-Host "Vault: $vault" -ForegroundColor Green
$lsPath  = Join-Path $vault ".obsidian\plugins\obsidian-livesync\data.json"
$rcpPath = Join-Path $vault ".obsidian\plugins\remember-cursor-position-enhanced\data.json"
if (-not (Test-Path $lsPath)) { Write-Host "No LiveSync config at $lsPath - is this the right vault?" -ForegroundColor Red; exit 1 }

# 0. Tailscale reachability (the #1 cause of a laptop going silent). Creds-free.
Write-Host "`nChecking Tailscale / CouchDB reachability..." -ForegroundColor Cyan
$tsCmd = Get-Command tailscale -ErrorAction SilentlyContinue
if ($tsCmd) {
	$st = (& tailscale status 2>&1 | Out-String)
	if ($st -match 'Logged out|stopped|Tailscale is stopped') { Write-Host "  !! Tailscale appears DOWN. Open the Tailscale app and Connect, then re-run." -ForegroundColor Red }
	else { Write-Host "  Tailscale is running." -ForegroundColor Green }
}
if ($CouchUrl) {
	try { Invoke-RestMethod "$CouchUrl/$DbName" -TimeoutSec 12 | Out-Null; Write-Host "  CouchDB reachable at $CouchUrl (open, no auth needed for this test)." -ForegroundColor Green }
	catch {
		$msg = $_.Exception.Message
		if ($msg -match '401|Unauthorized') { Write-Host "  CouchDB REACHABLE at $CouchUrl (401 = server answered; Tailscale path is good)." -ForegroundColor Green }
		elseif ($msg -match 'timed out|No such host|actively refused|remote name|Unable to connect') { Write-Host "  !! CANNOT reach $CouchUrl -- Tailscale is down or the URL is wrong. Fix Tailscale first." -ForegroundColor Red }
		else { Write-Host "  Reachability inconclusive: $msg" -ForegroundColor Yellow }
	}
} else { Write-Host "  (No -CouchUrl given, skipped the server test. Just make sure Tailscale shows Connected.)" -ForegroundColor DarkGray }

# 1. Capture Obsidian exe path, then close it so edits stick.
$proc = Get-Process Obsidian -ErrorAction SilentlyContinue | Select-Object -First 1
$exe = if ($proc -and $proc.Path) { $proc.Path } else { "$env:LOCALAPPDATA\Obsidian\Obsidian.exe" }
if ($proc) { Write-Host "`nClosing Obsidian..." -ForegroundColor Cyan; Get-Process Obsidian -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2 }

# 2. Patch LiveSync -> reliable mode + ignore log folders (connection/encryption untouched).
Write-Host "Patching LiveSync config (reliable mode)..." -ForegroundColor Cyan
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
Write-Host "  liveSync=off, periodic=10s, onStart/onSave/onOpen=on, history=off, logs ignored" -ForegroundColor Green

# 3. Patch RCP-E -> stop the debug-log flood.
if (Test-Path $rcpPath) {
	$rcp = Get-Content $rcpPath -Raw | ConvertFrom-Json
	Set-Prop $rcp 'logToFile' $false; Set-Prop $rcp 'debugLogging' $false; Set-Prop $rcp 'saveDebounceMs' 1500
	[System.IO.File]::WriteAllText($rcpPath, ($rcp | ConvertTo-Json -Depth 20), $enc)
	Write-Host "  RCP-E: logToFile=off, debugLogging=off, saveDebounceMs=1500" -ForegroundColor Green
} else { Write-Host "  (RCP-E config not found - enable the plugin, then re-run)" -ForegroundColor Yellow }

# 4. Clear the flood.
$logDir = Join-Path $vault 'rcp-enhanced-logs'
if (Test-Path $logDir) { Remove-Item $logDir -Recurse -Force; Write-Host "  Deleted rcp-enhanced-logs\ (the flooded log)" -ForegroundColor Green }
Get-ChildItem (Join-Path $vault 'livesync_log_*.md') -ErrorAction SilentlyContinue | Remove-Item -Force

# 5. Restart Obsidian so syncOnStart fires and it pulls the latest.
if (-not $NoRestart) {
	if (Test-Path $exe) { Start-Process $exe; Write-Host "`nReopened Obsidian -- syncOnStart is pulling the latest now." -ForegroundColor Green }
	else { Write-Host "`nReopen Obsidian manually (couldn't find Obsidian.exe at $exe)." -ForegroundColor Yellow }
}

Write-Host "`nDONE." -ForegroundColor Green
Write-Host "  It should sync within a few seconds of opening. If a note is still missing after ~30s," -ForegroundColor Green
Write-Host "  LiveSync settings -> 'Fetch everything from the remote database' (one-time lineage adopt)." -ForegroundColor Green
