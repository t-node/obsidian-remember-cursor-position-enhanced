<#
.SYNOPSIS
  RUN ON A DEVICE (e.g. the office laptop) to set Syncthing's fsWatcherDelayS for the vault folder,
  making cursor-position send/confirm fast. Self-contained: reads THIS machine's own Syncthing API key
  + GUI address from its local config.xml, so you don't need to know any keys.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\set-watcher-here.ps1
  powershell -ExecutionPolicy Bypass -File scripts\set-watcher-here.ps1 -DelayS 0.2 -FolderLabel Vault
#>
[CmdletBinding()]
param(
    [double]$DelayS = 0.1,
    [string]$FolderLabel = 'Vault'
)
$ErrorActionPreference = 'Stop'

$cfgPath = Join-Path $env:LOCALAPPDATA 'Syncthing\config.xml'
if (-not (Test-Path $cfgPath)) { Write-Host "Syncthing config not found at $cfgPath. Is Syncthing installed for this user?" -ForegroundColor Red; exit 1 }
[xml]$xml = Get-Content $cfgPath -Raw

$gui = $xml.configuration.gui
$apikey = $gui.apikey
$addr = $gui.address                      # e.g. 127.0.0.1:8384
$useTls = ($gui.tls -eq 'true')
$scheme = if ($useTls) { 'https' } else { 'http' }
$base = "${scheme}://$addr"

$folder = $xml.configuration.folder | Where-Object { $_.label -eq $FolderLabel } | Select-Object -First 1
if (-not $folder) { Write-Host "No Syncthing folder labelled '$FolderLabel'. Folders here: $(( $xml.configuration.folder | ForEach-Object { $_.label }) -join ', ')" -ForegroundColor Red; exit 1 }
$fid = $folder.id

# PS 5.1 can't do -SkipCertificateCheck; bypass cert validation globally for the https case instead.
if ($useTls) { try { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } } catch {} }
$h = @{ 'X-API-Key' = $apikey }

try {
    $f = Invoke-RestMethod -Uri "$base/rest/config/folders/$fid" -Headers $h -TimeoutSec 8
    $old = $f.fsWatcherDelayS
    $f.fsWatcherDelayS = $DelayS
    $f.fsWatcherEnabled = $true
    Invoke-RestMethod -Uri "$base/rest/config/folders/$fid" -Headers $h -Method Put `
        -Body ($f | ConvertTo-Json -Depth 12) -ContentType 'application/json' -TimeoutSec 10 | Out-Null
    Write-Host "OK: '$FolderLabel' fsWatcherDelayS $old -> $DelayS  (applied live, no restart needed)." -ForegroundColor Green
    # Drop a confirmation into the synced plugin-dist/ so the hub can verify this device's value remotely.
    try {
        $distDir = Join-Path $folder.path 'plugin-dist'
        if (Test-Path $distDir) {
            $ackFile = Join-Path $distDir ("watcher-{0}.json" -f $env:COMPUTERNAME)
            @{ host = $env:COMPUTERNAME; folder = $FolderLabel; fsWatcherDelayS = $DelayS; ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } |
                ConvertTo-Json | Set-Content -Path $ackFile -Encoding UTF8
        }
    } catch {}
} catch {
    Write-Host "Failed to reach Syncthing REST at $base : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Do it in the GUI instead: open $base -> Folder '$FolderLabel' -> Edit -> Advanced -> Watcher Delay = $DelayS." -ForegroundColor Yellow
    exit 1
}
