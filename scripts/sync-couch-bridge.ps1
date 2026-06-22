<#
  sync-couch-bridge.ps1  —  keep Windows able to reach CouchDB (which runs in WSL Docker).

  WHY THIS EXISTS
  ---------------
  CouchDB runs as a Docker container INSIDE WSL Ubuntu. Two things repeatedly broke sync:
    1. WSL not running  -> CouchDB unreachable for everyone (the 27h outage on 2026-06-21).
    2. The WSL2 localhost relay (wslrelay) wedges on Win10: it binds 127.0.0.1:5984 but
       stops forwarding, so Obsidian + Tailscale Serve get connection-refused / 502.
  This script sidesteps BOTH by:
    - ensuring WSL + CouchDB are up, and
    - publishing a STABLE Windows loopback port (5994) that forwards straight to the WSL
      VM IP (which is always reachable from Windows), refreshing it every run because the
      WSL IP changes on each boot. The relay is never used.

  Tailscale Serve and the laptop's Obsidian both point at http://127.0.0.1:5994 (static).
  Run it on demand, or let the scheduled task (logon + every 30 min) self-heal it.

  Needs elevation (netsh portproxy). Safe to run repeatedly (idempotent).
#>
[CmdletBinding()]
param([int]$Port = 5994, [string]$Distro = "Ubuntu", [string]$Database = "obsidian-vault")

$ErrorActionPreference = "Stop"
$cred = "obsidian:11111111"
$logDir = Join-Path $PSScriptRoot "..\debug-reports"
$log = Join-Path $logDir "bridge.log"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
function Note($m) { $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m; Add-Content -Path $log -Value $line; Write-Host $line }

Note "=== bridge run (port $Port -> $Distro CouchDB) ==="

# 1. Ensure WSL + CouchDB are up. Calling wsl auto-starts the distro; the container has
#    restart:unless-stopped so it returns once the docker daemon is back. /_up returns 401
#    (require_valid_user) or 200 when CouchDB is alive.
$up = ""
for ($i = 1; $i -le 20; $i++) {
  try { $up = (wsl -d $Distro -- bash -lc "curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://127.0.0.1:5984/_up" 2>$null).Trim() } catch { $up = "" }
  if ($up -eq "200" -or $up -eq "401") { break }
  Start-Sleep -Seconds 3
}
if ($up -ne "200" -and $up -ne "401") { Note "ERROR: CouchDB not healthy inside WSL after wait (last code='$up'). Aborting."; exit 1 }
Note "CouchDB healthy inside WSL (HTTP $up)"

# 2. Current WSL VM IP (changes per boot).
$wslip = (wsl -d $Distro -- bash -lc "hostname -I" 2>$null).Trim().Split(" ")[0]
if (-not $wslip) { Note "ERROR: could not read WSL IP. Aborting."; exit 1 }
Note "WSL IP = $wslip"

# 3. Reset the loopback portproxy to the current WSL IP.
netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=127.0.0.1 2>&1 | Out-Null
$add = netsh interface portproxy add v4tov4 listenport=$Port listenaddress=127.0.0.1 connectport=5984 connectaddress=$wslip 2>&1
if ($LASTEXITCODE -ne 0) { Note "ERROR: netsh portproxy add failed (need admin?): $add"; exit 1 }
Note "portproxy 127.0.0.1:$Port -> ${wslip}:5984 set"

# 4. Verify with an AUTHENTICATED read (the only correct health check; unauth GET / is 401 by design).
$h = @{ Authorization = ("Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($cred))) }
$ok = $false
for ($i = 1; $i -le 8; $i++) {
  try {
    $r = Invoke-RestMethod "http://127.0.0.1:$Port/$Database" -Headers $h -TimeoutSec 6
    Note ("VERIFIED: 127.0.0.1:{0}/{1} OK  doc_count={2} update_seq={3}" -f $Port, $Database, $r.doc_count, $r.update_seq.Substring(0, 6))
    $ok = $true; break
  } catch { Start-Sleep -Milliseconds 800 }
}
if (-not $ok) { Note "ERROR: bridge not serving after portproxy set. Aborting."; exit 1 }
Note "=== bridge OK ==="
exit 0
