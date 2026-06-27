<#
.SYNOPSIS
  Make cursor-position send + confirm as fast as possible by lowering Syncthing's fsWatcherDelayS
  (how long it waits after a file change before sending) on every reachable device.

.DESCRIPTION
  The dominant latency in "push my position -> it lands on the other device -> it confirms back" is
  Syncthing's fsWatcherDelayS. Default was 1s on each device; this sets it to $DelayS (0.2s) on the hub
  and on each ADB-reachable Android device (via an adb-forwarded REST call, same as sync-now.ps1).
  Connections are already DIRECT over Tailscale/LAN, so with a sub-second watcher the round-trip drops
  to well under a second. Keys/ports come from scripts/sync.config.ps1 (gitignored).

  The office laptop's Syncthing REST isn't reachable from here — set it in its own Syncthing GUI:
  Folder 'Vault' -> Advanced -> "Watcher delay" = 0.2 (or run this script there).

.EXAMPLE
  pwsh scripts/sync-speed.ps1            # set 0.2s everywhere reachable
  pwsh scripts/sync-speed.ps1 -DelayS 0.1
  pwsh scripts/sync-speed.ps1 -Show      # just report current values
#>
[CmdletBinding()]
param(
    [double]$DelayS = 0.2,
    [switch]$Show
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\sync.config.ps1"
$fid = $SyncConfig.SyncthingFolderId

function Set-Watcher([string]$base, [hashtable]$headers, [string]$label, [switch]$SkipCert) {
    # Android Syncthing serves its GUI over HTTPS (self-signed) — skip cert there. The hub is plain http.
    $extra = if ($SkipCert) { @{ SkipCertificateCheck = $true } } else { @{} }
    try {
        $folder = Invoke-RestMethod -Uri "$base/rest/config/folders/$fid" -Headers $headers -TimeoutSec 8 @extra
        if ($Show) { Write-Host ("  {0,-16} fsWatcherDelayS={1}" -f $label, $folder.fsWatcherDelayS); return }
        $old = $folder.fsWatcherDelayS
        $folder.fsWatcherDelayS = $DelayS
        $folder.fsWatcherEnabled = $true
        Invoke-RestMethod -Uri "$base/rest/config/folders/$fid" -Headers $headers -Method Put `
            -Body ($folder | ConvertTo-Json -Depth 12) -ContentType 'application/json' -TimeoutSec 10 @extra | Out-Null
        Write-Host ("  OK    {0,-16} fsWatcherDelayS {1} -> {2}" -f $label, $old, $DelayS) -ForegroundColor Green
    } catch {
        Write-Host ("  SKIP  {0,-16} {1}" -f $label, $_.Exception.Message) -ForegroundColor DarkGray
    }
}

Write-Host ("== Syncthing watcher delay ({0}) ==" -f ($Show ? 'current' : "-> ${DelayS}s")) -ForegroundColor Cyan

# Hub (this laptop).
Set-Watcher 'http://127.0.0.1:8384' @{ 'X-API-Key' = $SyncConfig.SyncthingHubApiKey } 'hub (laptop)'

# Android devices over adb-forwarded REST.
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source }
$connected = if ($adb) { (& $adb devices) | Where-Object { $_ -match '\sdevice$' } | ForEach-Object { ($_ -split '\s+')[0] } } else { @() }

foreach ($d in ($SyncConfig.SyncthingAndroid)) {
    # Match either USB serial or a wireless ip:5555 id whose ip is this device's Tailscale ip.
    $devIp = ($SyncConfig.Devices | Where-Object { $_.name -eq $d.name }).ip
    $adbId = @($d.serial, "${devIp}:5555") | Where-Object { $connected -contains $_ } | Select-Object -First 1
    if (-not $adbId) { Write-Host "  SKIP  $($d.name): not connected (USB/Tailscale adb)" -ForegroundColor DarkGray; continue }
    $port = $d.localPort
    & $adb -s $adbId forward "tcp:$port" 'tcp:8384' | Out-Null
    try {
        Set-Watcher "https://127.0.0.1:$port" @{ 'X-API-Key' = $d.apikey } $d.name -SkipCert
    } finally {
        & $adb -s $adbId forward --remove "tcp:$port" 2>$null | Out-Null
    }
}

Write-Host "`nOffice laptop: set it in its Syncthing GUI (Folder 'Vault' -> Advanced -> Watcher delay = $DelayS)." -ForegroundColor Cyan
if (-not $Show) { Write-Host "Done. Send + confirm should now round-trip in well under a second on online, same-network devices." -ForegroundColor Green }
