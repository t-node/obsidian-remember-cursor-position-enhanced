<#
.SYNOPSIS
  One tool to diagnose, reset, and verify the Obsidian cross-device cursor sync.

.DESCRIPTION
  The cursor-sync stack: RCP-E (per-device cursor-state/{deviceId}.json) -> Self-hosted
  LiveSync -> CouchDB on this laptop. This script owns every part EXCEPT the two Obsidian
  UI clicks that only Obsidian can perform ("Overwrite remote" and "Fetch everything").

  The laptop (C:\notes1) is ALWAYS the source of truth. A reset = wipe CouchDB clean,
  re-upload the laptop vault, then every other device fetches the fresh copy. Because each
  cursor file has a single writer, once lineages are unified nothing can conflict.

.PARAMETER Action
  doctor      (default) Read-only health report: CouchDB size, lock, ghost nodes, and a
              cross-device md5 comparison of every cursor-state file on every connected
              adb device + this laptop. Safe to run anytime. Scales to N devices.
  backup      Snapshot laptop configs + cursor-state + CouchDB milestone/security.
  patch       Normalize LiveSync + RCP-E config on the laptop and every connected phone/
              tablet (writeLogToTheFile=false, full ignore regex, useHistory=false, etc.).
              REQUIRES Obsidian CLOSED on every device being patched.
  wipe        Delete + recreate the CouchDB database empty (reclaims ALL bloat).
              Destructive to the REMOTE only; the laptop vault on disk is untouched.
  unlock      After every device has fetched: clear the LiveSync lock and rewrite
              accepted_nodes to the real current nodes only (drops ghost identities).
  verify      Same cross-device md5 comparison as doctor, plus a PASS/FAIL on whether
              every device's cursor-state files are byte-identical.

.PARAMETER CouchUrl   From scripts\sync.config.ps1 (override to change)
.PARAMETER CouchUser  From scripts\sync.config.ps1
.PARAMETER CouchPass  From scripts\sync.config.ps1
.PARAMETER DbName     From scripts\sync.config.ps1
.PARAMETER VaultDir   Laptop vault, from scripts\sync.config.ps1
.PARAMETER Yes        Skip the confirmation prompt on destructive actions (wipe).

.EXAMPLE
  pwsh scripts/sync-reset.ps1                 # health report
  pwsh scripts/sync-reset.ps1 -Action backup
  pwsh scripts/sync-reset.ps1 -Action patch  # Obsidian must be closed everywhere
  pwsh scripts/sync-reset.ps1 -Action wipe -Yes
  pwsh scripts/sync-reset.ps1 -Action unlock
  pwsh scripts/sync-reset.ps1 -Action verify
#>
[CmdletBinding()]
param(
	[ValidateSet('doctor','backup','patch','wipe','unlock','verify')]
	[string]$Action = 'doctor',
	[string]$CouchUrl,
	[string]$CouchUser,
	[string]$CouchPass,
	[string]$DbName,
	[string]$VaultDir,
	[switch]$Yes
)
. "$PSScriptRoot\_sync-config.ps1"

$ErrorActionPreference = 'Stop'
$DbUrl = "$CouchUrl/$DbName"
$AuthHeader = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${CouchUser}:${CouchPass}")))" }
$MilestoneId = '_local%2Fobsydian_livesync_milestone'

# The single source of truth for "calm" config. Keep IN SYNC across all devices.
# NOTE: cursor-state/ is now FULLY ignored (not just .diag-). The user chose total notification silence
# over cross-device scroll-position sync: syncing those high-churn files produced endless benign
# "merged automatically" conflict notices. To RE-ENABLE cross-device cursor sync later, change this back
# to '^rcp-enhanced-logs/|^cursor-state/\.diag-|^livesync_log'.
$GoodSyncIgnoreRegEx = '^rcp-enhanced-logs/|^cursor-state/|^livesync_log'

# --- helpers ---------------------------------------------------------------
function Couch($Method, $Path, $Body) {
	$uri = if ($Path -match '^https?://') { $Path } else { "$DbUrl/$Path" }
	$p = @{ Method = $Method; Uri = $uri; Headers = $AuthHeader; TimeoutSec = 30 }
	if ($Body) { $p.Body = ($Body | ConvertTo-Json -Depth 12 -Compress); $p.ContentType = 'application/json' }
	Invoke-RestMethod @p
}
function AdbDevices {
	# Returns the serials of every device in "device" state.
	(& adb devices) 2>$null | Select-String '\tdevice$' | ForEach-Object { ($_ -split '\t')[0] }
}
function PhoneVaultDir($serial) {
	# Find the Obsidian vault that contains a cursor-state dir on this device.
	$candidates = @(
		'/storage/emulated/0/Documents/Test',
		'/storage/emulated/0/ObsidianVault',
		'/storage/emulated/0/Documents'
	)
	foreach ($c in $candidates) {
		$hit = (& adb -s $serial shell "test -d '$c/cursor-state' && echo OK" 2>$null)
		if ($hit -match 'OK') { return $c }
	}
	# Fallback: search (slower) for any cursor-state dir under internal storage.
	$found = (& adb -s $serial shell "ls -d /storage/emulated/0/*/cursor-state 2>/dev/null | head -1" 2>$null)
	if ($found) { return ($found -replace '/cursor-state\s*$','').Trim() }
	return $null
}

# --- actions ---------------------------------------------------------------
function Invoke-Backup {
	$bk = Join-Path (Split-Path $VaultDir -Parent) ("$(Split-Path $VaultDir -Leaf)-RESET-BACKUP-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
	New-Item -ItemType Directory -Force -Path $bk | Out-Null
	Copy-Item "$VaultDir\.obsidian\plugins\obsidian-livesync\data.json" "$bk\livesync-data.json" -Force
	Copy-Item "$VaultDir\.obsidian\plugins\remember-cursor-position-enhanced\data.json" "$bk\rcpe-data.json" -Force -ErrorAction SilentlyContinue
	Copy-Item "$VaultDir\cursor-state" "$bk\cursor-state" -Recurse -Force
	try { (Couch GET "_security") | ConvertTo-Json -Depth 6 | Out-File "$bk\couch-security.json" -Encoding utf8 } catch {}
	try { (Couch GET $MilestoneId) | ConvertTo-Json -Depth 10 | Out-File "$bk\milestone.json" -Encoding utf8 } catch {}
	Write-Host "Backup -> $bk" -ForegroundColor Green
}

function Invoke-Doctor {
	Write-Host "`n=== CouchDB ===" -ForegroundColor Cyan
	$info = Couch GET ''
	$file = [math]::Round($info.sizes.file/1MB,1); $active = [math]::Round($info.sizes.active/1MB,1)
	Write-Host ("docs={0}  deleted={1}  update_seq~{2}  disk={3}MB  active={4}MB" -f `
		$info.doc_count, $info.doc_del_count, ($info.update_seq -split '-')[0], $file, $active)
	if ($active -gt 40) { Write-Host "  ! active size high for a ~10MB vault (orphan-chunk bloat) -> run a wipe." -ForegroundColor Yellow }

	Write-Host "`n=== LiveSync milestone (lock / nodes) ===" -ForegroundColor Cyan
	$m = Couch GET $MilestoneId
	$lockColor = if ($m.locked) { 'Yellow' } else { 'Green' }
	Write-Host ("locked={0}" -f $m.locked) -ForegroundColor $lockColor
	$live = @(); $ghost = @()
	foreach ($n in $m.node_info.PSObject.Properties) {
		$vault = $n.Value.vault_name
		$tag = if ($vault -in @('notes1','Test','ObsidianVault','Notes')) { $live += $n.Name; 'LIVE ' } else { $ghost += $n.Name; 'ghost' }
		Write-Host ("  [{0}] {1,-12} vault='{2}'  last={3}" -f $tag, $n.Name, $vault, $n.Value.last_connected)
	}
	if ($ghost.Count) { Write-Host ("  ! {0} ghost node(s) -> 'unlock' action rewrites accepted_nodes to live only." -f $ghost.Count) -ForegroundColor Yellow }

	Write-Host "`n=== Cursor-state across devices ===" -ForegroundColor Cyan
	Compare-CursorState | Out-Null
}

function Get-DeviceFiles {
	# Returns a hashtable: deviceLabel -> @{ file -> md5 } for laptop + every adb device.
	$result = [ordered]@{}
	$lap = @{}
	Get-ChildItem "$VaultDir\cursor-state" -Filter '*.json' | Where-Object { $_.Name -notlike '.diag-*' } | ForEach-Object {
		$lap[$_.Name] = (Get-FileHash $_.FullName -Algorithm MD5).Hash.ToLower()
	}
	$result['laptop(notes1)'] = $lap
	foreach ($serial in AdbDevices) {
		$vd = PhoneVaultDir $serial
		if (-not $vd) { Write-Host "  (no vault found on $serial)" -ForegroundColor DarkGray; continue }
		$names = (& adb -s $serial shell "ls $vd/cursor-state/*.json 2>/dev/null" 2>$null) |
			ForEach-Object { ($_ -split '/')[-1].Trim() } | Where-Object { $_ -and $_ -notlike '.diag-*' }
		$map = @{}
		foreach ($nm in $names) {
			$md5 = (& adb -s $serial shell "md5sum $vd/cursor-state/$nm 2>/dev/null" 2>$null)
			if ($md5) { $map[$nm] = (($md5 -split '\s+')[0]).Trim().ToLower() }
		}
		$result["$serial`:$vd"] = $map
	}
	return $result
}

function Compare-CursorState {
	$all = Get-DeviceFiles
	$files = $all.Values | ForEach-Object { $_.Keys } | Sort-Object -Unique
	$labels = @($all.Keys)
	$pass = $true
	foreach ($f in $files) {
		$hashes = foreach ($l in $labels) { $all[$l][$f] }
		$distinct = $hashes | Where-Object { $_ } | Sort-Object -Unique
		$state = if ($distinct.Count -le 1) { 'OK  ' } else { $pass = $false; 'DIFF' }
		$color = if ($state -eq 'OK  ') { 'Green' } else { 'Yellow' }
		Write-Host ("  [{0}] {1}" -f $state, $f) -ForegroundColor $color
		if ($state -eq 'DIFF') {
			foreach ($l in $labels) {
				$h = $all[$l][$f]; if (-not $h) { $h = '(missing)' }
				Write-Host ("        {0,-28} {1}" -f $l, $h) -ForegroundColor DarkGray
			}
		}
	}
	return $pass
}

function Patch-LiveSyncJson($json) {
	$json.writeLogToTheFile = $false
	$json.useHistory = $false
	$json.skipOlderFilesOnSync = $false
	# RELIABLE (batch) mode — liveSync OFF so the periodic fallback runs (see sync-kick.ps1).
	$json.liveSync = $false
	$json.syncOnStart = $true
	$json.syncOnSave = $true
	$json.syncOnFileOpen = $true
	$json.periodicReplication = $true
	$json.periodicReplicationInterval = 10
	$json.automaticallyDeleteMetadataOfDeletedFiles = 7
	$json.syncIgnoreRegEx = $GoodSyncIgnoreRegEx
	# QUIET MODE — no notifications unless something actually breaks (user requirement).
	$json.useRequestAPI = $true                  # use Obsidian request API (no native fetch) -> kills the CORS warning
	$json.showStatusOnEditor = $false            # no flashing sync status overlay
	$json.hideFileWarningNotice = $true          # no "file is not target by local DB" notices
	$json.lessInformationInLog = $true           # minimal log chatter
	$json.showMergeDialogOnlyOnActive = $true    # merge prompts only for the file you're editing
	# AUTO-resolve conflicts by newest (ephemeral cursor-state files get stuck conflict branches from
	# rebuilds; this clears them silently). checkConflictOnlyOnOpen=true POSTPONES + still nags, so OFF.
	$json.resolveConflictsByNewerFile = $true
	$json.checkConflictOnlyOnOpen = $false
	$json.suppressNotifyHiddenFilesChange = $true
	$json.disableCheckingConfigMismatch = $true  # no config-mismatch nags
	return $json
}

function Invoke-Patch {
	Write-Host "Patching LiveSync config (Obsidian MUST be closed on each device)..." -ForegroundColor Cyan
	# Laptop
	$lp = "$VaultDir\.obsidian\plugins\obsidian-livesync\data.json"
	$j = Get-Content $lp -Raw | ConvertFrom-Json
	$j = Patch-LiveSyncJson $j
	($j | ConvertTo-Json -Depth 20) | Out-File $lp -Encoding utf8
	Write-Host "  laptop: patched" -ForegroundColor Green
	# Devices
	foreach ($serial in AdbDevices) {
		$vd = PhoneVaultDir $serial; if (-not $vd) { continue }
		$rp = "$vd/.obsidian/plugins/obsidian-livesync/data.json"
		$raw = (& adb -s $serial shell "cat '$rp'" 2>$null) -join "`n"
		if (-not $raw) { Write-Host "  ${serial}: no livesync config" -ForegroundColor DarkGray; continue }
		$dj = $raw | ConvertFrom-Json
		$dj = Patch-LiveSyncJson $dj
		$tmp = New-TemporaryFile
		($dj | ConvertTo-Json -Depth 20) | Out-File $tmp -Encoding utf8
		& adb -s $serial push $tmp $rp 2>$null | Out-Null
		Remove-Item $tmp -Force
		# remove already-written livesync log files so they don't re-sync
		& adb -s $serial shell "rm -f $vd/livesync_log_*.md" 2>$null | Out-Null
		Write-Host "  ${serial}: patched ($vd)" -ForegroundColor Green
	}
	Remove-Item "$VaultDir\livesync_log_*.md" -Force -ErrorAction SilentlyContinue
	Write-Host "Done. Reopen Obsidian on each patched device." -ForegroundColor Green
}

function Invoke-Wipe {
	Write-Host "WIPE: delete + recreate CouchDB '$DbName' (remote only; laptop vault on disk is safe)." -ForegroundColor Yellow
	if (-not $Yes) {
		$c = Read-Host "Type WIPE to confirm"
		if ($c -ne 'WIPE') { Write-Host "Aborted."; return }
	}
	try { Couch DELETE '' | Out-Null; Write-Host "  deleted" } catch { Write-Host "  (db absent or already deleted)" }
	Start-Sleep -Milliseconds 500
	Couch PUT '' | Out-Null
	Couch PUT '_security' @{ members = @{ roles = @('_admin') }; admins = @{ roles = @('_admin') } } | Out-Null
	Write-Host "  recreated empty + secured" -ForegroundColor Green
	Write-Host "`nNEXT (Obsidian UI, cannot be scripted):" -ForegroundColor Cyan
	Write-Host "  1. Open Obsidian on the LAPTOP. LiveSync may warn the remote is empty/mismatched."
	Write-Host "     Run command 'Self-hosted LiveSync: Overwrite remote' (uploads the laptop vault fresh)."
	Write-Host "  2. On EACH other device: open Obsidian, on the lock dialog choose"
	Write-Host "     'Fetch everything from the remote (rebuild local)'."
	Write-Host "  3. When all devices have fetched, run:  scripts/sync-reset.ps1 -Action unlock"
	Write-Host "  4. Confirm with:                        scripts/sync-reset.ps1 -Action verify"
}

function Invoke-Unlock {
	$m = Couch GET $MilestoneId
	$live = @()
	foreach ($n in $m.node_info.PSObject.Properties) {
		if ($n.Value.vault_name -in @('notes1','Test','ObsidianVault','Notes')) { $live += $n.Name }
	}
	$live = $live | Sort-Object -Unique
	$m.locked = $false
	$m.accepted_nodes = $live
	$m.cleaned = $true
	Couch PUT $MilestoneId $m | Out-Null
	Write-Host ("Unlocked. accepted_nodes -> {0}" -f ($live -join ', ')) -ForegroundColor Green
}

function Invoke-Verify {
	Write-Host "=== VERIFY: cursor-state byte-identical across all devices ===" -ForegroundColor Cyan
	$pass = Compare-CursorState
	$info = Couch GET ''; $active = [math]::Round($info.sizes.active/1MB,1)
	$m = Couch GET $MilestoneId
	Write-Host ("`nCouchDB active={0}MB  locked={1}  docs={2}" -f $active, $m.locked, $info.doc_count)
	if ($pass -and -not $m.locked -and $active -lt 60) {
		Write-Host "`nPASS: all cursor-state files match, unlocked, no bloat." -ForegroundColor Green
	} else {
		Write-Host "`nNOT YET: see DIFF rows / lock / size above." -ForegroundColor Yellow
	}
}

switch ($Action) {
	'doctor' { Invoke-Doctor }
	'backup' { Invoke-Backup }
	'patch'  { Invoke-Patch }
	'wipe'   { Invoke-Wipe }
	'unlock' { Invoke-Unlock }
	'verify' { Invoke-Verify }
}
