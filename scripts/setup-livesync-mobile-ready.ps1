#Requires -Version 5.1
<#
.SYNOPSIS
  Prepare LiveSync for phone/tablet: CouchDB + Tailscale HTTPS + RCP-E + phone setup guide.
#>
param(
    [string]$VaultPath = 'C:\notes1',
    [string]$CouchDbPassword,
    [string]$E2EPassphrase,
    [string]$Database = 'obsidian-vault',
    [switch]$SkipDeploy
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$ComposeDir = Join-Path $PSScriptRoot 'livesync'
$StartScript = Join-Path $ComposeDir 'start-couchdb.sh'

function Write-Step([string]$n, [string]$text) {
    Write-Host ''
    Write-Host "[$n] $text" -ForegroundColor Cyan
}

function Find-TailscaleExe {
    $candidates = @(
        'tailscale',
        "${env:ProgramFiles}\Tailscale\tailscale.exe",
        "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe"
    )
    foreach ($c in $candidates) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { return $c }
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Test-CouchDbAuth([string]$baseUrl, [string]$user, [string]$pass, [string]$db) {
    $pair = "${user}:${pass}"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $basic = [Convert]::ToBase64String($bytes)
    try {
        $r = Invoke-RestMethod -Uri "$baseUrl/$db" -Headers @{ Authorization = "Basic $basic" } -TimeoutSec 10
        return [pscustomobject]@{ Ok = $true; DocCount = $r.doc_count; Raw = $r }
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Get-LanIPv4 {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.PrefixOrigin -ne 'WellKnown'
        } |
        Sort-Object -Property InterfaceMetric |
        Select-Object -First 1 -ExpandProperty IPAddress
    return $ip
}

Write-Host ''
Write-Host '================================================' -ForegroundColor Green
Write-Host ' LiveSync mobile-ready setup (laptop)' -ForegroundColor Green
Write-Host '================================================' -ForegroundColor Green
Write-Host ''

if (-not (Test-Path $VaultPath)) {
    throw "Vault not found: $VaultPath"
}

if (-not $CouchDbPassword) {
    $CouchDbPassword = Read-Host 'CouchDB password for user obsidian'
}
if (-not $E2EPassphrase) {
    $E2EPassphrase = Read-Host 'LiveSync E2E passphrase (same on all devices)'
}

# --- 1 CouchDB via WSL ---
Write-Step '1/5' 'Starting CouchDB in WSL Docker...'
if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    throw 'WSL not found. Install WSL + Docker in Ubuntu first.'
}

$winPath = $StartScript -replace '\\', '/'
if ($winPath -match '^([A-Za-z]):(.*)$') {
    $wslPath = '/mnt/{0}{1}' -f $Matches[1].ToLower(), $Matches[2]
} else {
    $wslPath = $winPath
}
$escapedPass = $CouchDbPassword -replace "'", "'\\''"
wsl -e bash -c "sed -i 's/\r$//' '$wslPath' && export COUCHDB_PASSWORD='$escapedPass' && bash '$wslPath'"
if ($LASTEXITCODE -ne 0) {
    throw 'CouchDB failed to start in WSL'
}
Write-Host '  CouchDB is up on http://127.0.0.1:5984' -ForegroundColor Green

$localCheck = Test-CouchDbAuth 'http://127.0.0.1:5984' 'obsidian' $CouchDbPassword $Database
if (-not $localCheck.Ok) {
    throw "CouchDB auth failed: $($localCheck.Error)"
}
Write-Host "  doc_count: $($localCheck.DocCount)" -ForegroundColor Green

# --- 2 Tailscale HTTPS ---
Write-Step '2/5' 'Configuring Tailscale HTTPS for phone (Android needs HTTPS)...'
$tailscale = Find-TailscaleExe
$httpsUrl = $null
$tailscaleIp = $null
$lanIp = Get-LanIPv4

if ($tailscale) {
    $serveStatus = ''
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $tailscale serve --bg --https 443 http://127.0.0.1:5984 2>&1 | Out-Host
        Start-Sleep -Seconds 2
        $serveStatus = & $tailscale serve status 2>&1 | Out-String
        Write-Host $serveStatus

        if ($serveStatus -match 'Logged out') {
            Write-Host '  Tailscale is installed but logged out. Sign in, then re-run.' -ForegroundColor Yellow
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }

    if ($serveStatus -match '(https://[^\s]+)') {
        $httpsUrl = $Matches[1].TrimEnd('/')
    }

    $ErrorActionPreference = 'Continue'
    $statusJson = & $tailscale status --json 2>&1 | Out-String
    $ErrorActionPreference = $prevEap
    if ($statusJson -match '"TailscaleIPs"\s*:\s*\[\s*"([0-9.]+)"') {
        $tailscaleIp = $Matches[1]
    }
    if (-not $httpsUrl -and $statusJson -match '"DNSName"\s*:\s*"([^"]+)"') {
        $dns = $Matches[1].TrimEnd('.')
        $httpsUrl = "https://$dns"
    }

    if ($httpsUrl) {
        Write-Host "  Phone URL (HTTPS): $httpsUrl" -ForegroundColor Green
        try {
            $null = Invoke-WebRequest -Uri $httpsUrl -UseBasicParsing -TimeoutSec 15
            Write-Host '  HTTPS endpoint reachable from laptop' -ForegroundColor Green
        } catch {
            Write-Host "  HTTPS test warning: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host '  Ensure Tailscale is connected on phone too.' -ForegroundColor Yellow
        }
    }
} else {
    Write-Host '  Tailscale NOT installed on Windows.' -ForegroundColor Yellow
    Write-Host '  Install from https://tailscale.com/download then re-run this script.' -ForegroundColor Yellow
    Write-Host '  Android Obsidian cannot use http://127.0.0.1 from your phone.' -ForegroundColor Yellow
}

# --- 3 RCP-E deploy ---
if (-not $SkipDeploy) {
    Write-Step '3/5' 'Deploying RCP-E plugin...'
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        $env:OBSIDIAN_VAULT_PLUGIN_DIR = Join-Path $VaultPath '.obsidian\plugins\remember-cursor-position-enhanced'
        Push-Location $RepoRoot
        try {
            npm run deploy 2>&1 | Out-Host
            Write-Host '  RCP-E deployed. Ctrl+R in Obsidian.' -ForegroundColor Green
        } finally {
            Pop-Location
        }
    } else {
        Write-Host '  npm not found - skip deploy; run: npm run deploy' -ForegroundColor Yellow
    }
} else {
    Write-Step '3/5' 'Skipping RCP-E deploy (-SkipDeploy)'
}

# --- 4 Obsidian manual steps ---
Write-Step '4/5' 'Laptop Obsidian - manual steps (cannot be scripted)...'

$laptopRemoteUrl = if ($httpsUrl) { $httpsUrl } else { "http://${lanIp}:5984" }

Write-Host ''
Write-Host '  Open Obsidian on LAPTOP:' -ForegroundColor Yellow
Write-Host '    Settings -> Self-hosted LiveSync -> Remote Configuration'
Write-Host "    Edit couch URL to: $laptopRemoteUrl"
Write-Host "    Database: $Database  User: obsidian"
Write-Host '    Test connection -> must pass'
Write-Host '    Setup tab -> Copy NEW Setup URI -> send to phone'
Write-Host ''

# --- 5 Write phone guide ---
Write-Step '5/5' 'Writing phone setup guide...'
$guidePath = Join-Path $VaultPath 'PHONE-LIVESYNC-SETUP.txt'
if ($httpsUrl) {
    $phoneUrl = $httpsUrl
} else {
    $phoneUrl = "http://${lanIp}:5984 (LAN - may fail on Android without Tailscale)"
}
$tsIpLine = if ($tailscaleIp) { $tailscaleIp } else { 'install Tailscale' }
$httpsLine = if ($httpsUrl) { $httpsUrl } else { 're-run script after installing Tailscale' }
$docCount = $localCheck.DocCount
$generated = Get-Date -Format 'yyyy-MM-dd HH:mm'

$guide = @"
================================================================================
PHONE / TABLET LiveSync setup - generated $generated
================================================================================

WHY PHONE FAILED WITH 127.0.0.1
  127.0.0.1 on phone = the phone itself, not your laptop.
  Android also requires HTTPS (use Tailscale URL below).

COUCHDB
  Local:    http://127.0.0.1:5984/$Database
  Phone:    $phoneUrl
  User:     obsidian
  doc_count on server: $docCount

LAPTOP - do once before phone
  1. Remote Configuration -> edit couch connection URL = $laptopRemoteUrl
  2. Test connection
  3. Setup tab -> Copy NEW Setup URI -> send to phone

PHONE - steps
  1. Install Tailscale (same account as laptop)
  2. Pause Syncthing for this vault
  3. LiveSync -> Setup -> Use -> paste NEW Setup URI
  4. E2E passphrase (same as laptop)
  5. Fetch failed? -> Skip and proceed
  6. JOIN server / Fetch from remote (NOT overwrite)
  7. Send all chunks? -> NO
  8. Wait 15-30 min, Obsidian open on Wi-Fi
  9. BRAT -> t-node/obsidian-remember-cursor-position-enhanced
  10. RCP-E state folder = cursor-state

TAILSCALE
  Laptop Tailscale IP: $tsIpLine
  HTTPS URL: $httpsLine

WSL start CouchDB after reboot:
  cd /mnt/c/obsidian-remember-cursor-position/scripts/livesync
  docker compose up -d

================================================================================
"@

Set-Content -Path $guidePath -Value $guide -Encoding UTF8

Write-Host ''
Write-Host '================================================' -ForegroundColor Green
Write-Host ' DONE (automated parts)' -ForegroundColor Green
Write-Host '================================================' -ForegroundColor Green
Write-Host ''
Write-Host "Guide written: $guidePath"
Write-Host ''
Write-Host 'YOU MUST STILL DO IN OBSIDIAN ON LAPTOP:' -ForegroundColor Yellow
Write-Host "  1. Change Remote URL to: $laptopRemoteUrl"
Write-Host '  2. Copy NEW Setup URI -> paste on phone'
Write-Host ''
if (-not $httpsUrl) {
    Write-Host 'INSTALL TAILSCALE on laptop + phone, then re-run this script.' -ForegroundColor Red
}
