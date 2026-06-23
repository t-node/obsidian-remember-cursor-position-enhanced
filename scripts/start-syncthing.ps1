<#
  start-syncthing.ps1 — watchdog that keeps the Syncthing hub running.
  Run at logon + every 15 min by the ObsidianSyncthing scheduled task. If Syncthing isn't
  running, (re)start it. Idempotent, no elevation needed. Logs to debug-reports/syncthing-watch.log.
#>
$dir = "$env:LOCALAPPDATA\Syncthing"
$exe = "$dir\syncthing.exe"
$logDir = Join-Path $PSScriptRoot "..\debug-reports"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir "syncthing-watch.log"
function Note($m) { Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m) }

if (-not (Test-Path $exe)) { Note "ERROR: syncthing.exe missing at $exe"; exit 1 }
if (Get-Process syncthing -ErrorAction SilentlyContinue) { exit 0 }   # already running, nothing to do
Start-Process -FilePath $exe -ArgumentList "serve","--home=$dir","--no-browser","--allow-newer-config" -WindowStyle Hidden
Note "started Syncthing (was not running)"
exit 0
