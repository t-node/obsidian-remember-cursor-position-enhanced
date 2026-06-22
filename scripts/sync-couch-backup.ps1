<#
  sync-couch-backup.ps1  —  snapshot the CouchDB database that lives in WSL Docker.

  CouchDB data is the Docker named volume 'livesync_couchdb-data' (mounted at /opt/couchdb/data).
  This tars that volume to a timestamped .tgz on the Windows side and keeps the newest N.
  CouchDB's data files are append-only / crash-consistent, so a hot snapshot is safe for
  personal single-node use. Restore = stop the container, wipe the volume, untar back in.

  Runs on demand or via the ObsidianCouchBackup scheduled task (at logon + daily).
  Does NOT need elevation.
#>
[CmdletBinding()]
param(
  [string]$BackupDir = "C:\notes1-couchdb-backups",
  [int]$Keep = 14,
  [string]$Distro = "Ubuntu",
  [string]$Volume = "livesync_couchdb-data"
)
$ErrorActionPreference = "Stop"
$logDir = Join-Path $PSScriptRoot "..\debug-reports"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir "couch-backup.log"
function Note($m) { $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m; Add-Content -Path $log -Value $line; Write-Host $line }

Note "=== backup run (volume $Volume) ==="

if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

# Ensure WSL + docker are up (calling wsl auto-starts the distro).
$ok = $false
for ($i = 1; $i -le 15; $i++) {
  $st = (wsl -d $Distro -- bash -lc "docker inspect -f '{{.State.Running}}' obsidian-livesync-couchdb 2>/dev/null" 2>$null).Trim()
  if ($st -eq "true") { $ok = $true; break }
  Start-Sleep -Seconds 3
}
if (-not $ok) { Note "ERROR: CouchDB container not running; aborting backup."; exit 1 }

# Windows path -> WSL /mnt path
$drive = $BackupDir.Substring(0, 1).ToLower()
$rest = $BackupDir.Substring(2).Replace('\', '/')
$wslBackup = "/mnt/$drive$rest"
$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$name = "couchdb-$ts.tgz"

# Tar the volume using the couchdb image (already present; has tar). Volume read-only.
$cmd = "docker run --rm -v ${Volume}:/data:ro -v '${wslBackup}':/backup couchdb:3.4 tar czf /backup/$name -C /data . 2>&1"
$res = wsl -d $Distro -- bash -lc "$cmd" 2>&1
$file = Join-Path $BackupDir $name
if (-not (Test-Path $file) -or (Get-Item $file).Length -lt 1024) {
  Note "ERROR: backup file missing/too small. docker said: $res"
  exit 1
}
$mb = [math]::Round((Get-Item $file).Length / 1MB, 1)
Note "wrote $name ($mb MB)"

# Rotation: keep newest $Keep.
$all = Get-ChildItem -Path $BackupDir -Filter "couchdb-*.tgz" | Sort-Object LastWriteTime -Descending
if ($all.Count -gt $Keep) {
  $all | Select-Object -Skip $Keep | ForEach-Object { Remove-Item $_.FullName -Force; Note "pruned old backup $($_.Name)" }
}
Note ("=== backup OK ({0} kept) ===" -f ([math]::Min($all.Count, $Keep)))
exit 0
