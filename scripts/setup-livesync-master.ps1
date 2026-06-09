#Requires -Version 5.1
<#
.SYNOPSIS
  Master setup: CouchDB + RCP-E deploy + vault tweaks. Run on the laptop with your complete vault.

.PARAMETER VaultPath
  Obsidian vault root (default: C:\notes1).

.PARAMETER CouchDbPassword
  CouchDB password for user "obsidian". Prompted if omitted (min 8 chars).

.PARAMETER E2EPassphrase
  LiveSync end-to-end encryption passphrase — same on all 4 devices. Prompted if omitted.

.PARAMETER Database
  CouchDB database name (default: obsidian-vault).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup-livesync.ps1
#>
param(
    [string]$VaultPath = 'C:\notes1',
    [string]$CouchDbPassword,
    [string]$E2EPassphrase,
    [string]$Database = 'obsidian-vault'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$ComposeDir = Join-Path $PSScriptRoot 'livesync'
$LocalConfigPath = Join-Path $ComposeDir '.local-setup.json'

function Write-Step([string]$n, [string]$text) {
    Write-Host ''
    Write-Host "[$n] $text" -ForegroundColor Cyan
}

function Test-Command([string]$name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Green
Write-Host ' LiveSync + RCP-E — master setup' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Green
Write-Host ''
Write-Host 'This script automates everything on THIS laptop that can be scripted:'
Write-Host '  - CouchDB (Docker)'
Write-Host '  - RCP-E plugin build + deploy'
Write-Host '  - cursor-state/ excluded from search'
Write-Host '  - A cheat sheet with your connection values'
Write-Host ''
Write-Host 'You still do ~5 minutes in Obsidian (LiveSync connect) + ~5 min per other device.' -ForegroundColor Yellow
Write-Host ''

# --- inputs ---
if (-not (Test-Path $VaultPath)) {
    Write-Error "Vault not found: $VaultPath. Pass -VaultPath 'D:\your\vault'."
}

if (-not $CouchDbPassword) {
    $CouchDbPassword = Read-Host 'CouchDB password for user obsidian (min 8 chars, save this)'
}
if ($CouchDbPassword.Length -lt 8) {
    Write-Error 'CouchDB password must be at least 8 characters.'
}

if (-not $E2EPassphrase) {
    $E2EPassphrase = Read-Host 'LiveSync E2E passphrase (same on all 4 devices — save this)'
}
if ($E2EPassphrase.Length -lt 8) {
    Write-Error 'E2E passphrase must be at least 8 characters.'
}

if (-not (Test-Command docker)) {
    Write-Error 'Docker not found. Install Docker Desktop, start it, then re-run this script.'
}
if (-not (Test-Command node)) {
    Write-Error 'Node.js not found. Install from https://nodejs.org then re-run.'
}

$tailscaleIp = $null
if (Test-Command tailscale) {
    try {
        $tailscaleIp = (tailscale ip -4 2>$null | Select-Object -First 1).Trim()
    } catch { }
}
if (-not $tailscaleIp) {
    Write-Host 'Tailscale: not detected. Install on all 4 devices before connecting phones/tablet.' -ForegroundColor Yellow
}

# --- 1 deploy RCP-E ---
Write-Step '1/4' 'Building and deploying RCP-E to vault...'
$pluginDir = Join-Path $VaultPath '.obsidian\plugins\remember-cursor-position-enhanced'
$env:OBSIDIAN_VAULT_PLUGIN_DIR = $pluginDir
Push-Location $RepoRoot
try {
    npm test
    if ($LASTEXITCODE -ne 0) { throw 'npm test failed' }
    npm run deploy
    if ($LASTEXITCODE -ne 0) { throw 'npm run deploy failed' }
} finally {
    Pop-Location
}
Write-Host '  RCP-E deployed. Reload Obsidian on this laptop after the script finishes (Ctrl+R).' -ForegroundColor Green

# --- 2 vault excluded files ---
Write-Step '2/4' 'Adding cursor-state/ to Obsidian excluded files...'
$appJsonPath = Join-Path $VaultPath '.obsidian\app.json'
if (-not (Test-Path $appJsonPath)) {
    @{ promptDelete = $false; userIgnoreFilters = @('cursor-state/') } | ConvertTo-Json | Set-Content $appJsonPath -Encoding UTF8
} else {
    $raw = Get-Content $appJsonPath -Raw
    $obj = $raw | ConvertFrom-Json
    if (-not $obj.PSObject.Properties['userIgnoreFilters']) {
        $obj | Add-Member -NotePropertyName userIgnoreFilters -NotePropertyValue @()
    }
    $filters = [System.Collections.ArrayList]@($obj.userIgnoreFilters)
    if ($filters -notcontains 'cursor-state/') {
        [void]$filters.Add('cursor-state/')
        $obj.userIgnoreFilters = $filters.ToArray()
        $obj | ConvertTo-Json -Depth 10 | Set-Content $appJsonPath -Encoding UTF8
    }
}
Write-Host '  Done.' -ForegroundColor Green

# --- 3 CouchDB ---
Write-Step '3/4' 'Starting CouchDB (Docker)...'
$env:COUCHDB_PASSWORD = $CouchDbPassword
Push-Location $ComposeDir
try {
    docker compose up -d --force-recreate
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $null = Invoke-RestMethod -Uri 'http://127.0.0.1:5984' -Method Get -TimeoutSec 2
            $ready = $true
            break
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $ready) {
        Write-Error 'CouchDB did not start. Run: docker compose -f scripts/livesync/docker-compose.yml logs'
    }

    $pair = "obsidian:$CouchDbPassword"
    $basic = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    $headers = @{ Authorization = "Basic $basic" }
    $dbUrl = "http://127.0.0.1:5984/$Database"
    try {
        Invoke-RestMethod -Uri $dbUrl -Method Put -Headers $headers | Out-Null
        Write-Host "  Database created: $Database" -ForegroundColor Green
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 412) {
            Write-Host "  Database already exists: $Database" -ForegroundColor Yellow
        } else { throw }
    }
} finally {
    Pop-Location
}

# --- 4 save cheat sheet ---
Write-Step '4/4' 'Writing cheat sheet...'

$localUri = "http://127.0.0.1:5984/$Database"
$remoteUri = if ($tailscaleIp) { "http://${tailscaleIp}:5984/$Database" } else { 'http://<TAILSCALE-IP>:5984/' + $Database }

$config = @{
    createdAt       = (Get-Date).ToString('o')
    vaultPath       = $VaultPath
    couchDbUser     = 'obsidian'
    couchDbPassword = $CouchDbPassword
    database        = $Database
    localUri        = $localUri
    remoteUri       = $remoteUri
    tailscaleIp     = $tailscaleIp
    e2ePassphrase   = $E2EPassphrase
    rcpStateDir     = 'cursor-state'
}
$config | ConvertTo-Json | Set-Content $LocalConfigPath -Encoding UTF8

$cheatPath = Join-Path $VaultPath 'LIVESYNC-NEXT-STEPS.txt'
$cheat = @"
================================================================================
LIVESYNC + RCP-E — YOUR VALUES (generated $(Get-Date -Format 'yyyy-MM-dd HH:mm'))
================================================================================

AUTOMATED BY SCRIPT (done):
  [x] CouchDB running on this laptop (Docker)
  [x] RCP-E v2.1+ deployed to vault
  [x] cursor-state/ added to excluded files

YOU PROVIDE (already entered when running script):
  CouchDB password:  (saved in scripts/livesync/.local-setup.json on dev machine)
  E2E passphrase:    (same on all 4 devices)

CONNECTION VALUES — copy into Obsidian LiveSync on MASTER laptop:
  URI:        $localUri
  Username:   obsidian
  Password:   (your CouchDB password)
  E2E:        (your E2E passphrase)
  Mode:       LiveSync
  First sync: Overwrite remote with local

FOR PHONE / TABLET / OTHER LAPTOP (after Tailscale installed):
  URI:        $remoteUri
  (same username, password, E2E)
  Or paste Setup URI from master after step A6 below.

================================================================================
DO THESE STEPS IN ORDER
================================================================================

BEFORE OBSIDIAN (one-time, all 4 devices):
  [ ] Install Tailscale — same account on laptop, laptop, phone, tablet
  [ ] Pause Syncthing for this vault ONLY (all devices) — do not delete vault yet
  [ ] Zip backup of vault: $VaultPath

MASTER LAPTOP — Obsidian (~5 minutes):
  A1. Ctrl+R in Obsidian (reload after plugin deploy)
  A2. Settings → Community plugins → Browse → "Self-hosted LiveSync" → Install + Enable
  A3. Open LiveSync settings → Connect / Setup
  A4. Enter URI, username, password, E2E passphrase (see CONNECTION VALUES above)
  A5. Sync mode: LiveSync. First run: Overwrite remote with local. Wait until finished.
  A6. LiveSync settings → Copy setup URI (save to Notes app for other devices)

  RCP-E check:
  A7. Settings → RCP-E → State folder = cursor-state (default)
  A8. Optional: BRAT plugin for future updates — t-node/obsidian-remember-cursor-position-enhanced

OTHER 3 DEVICES (~5 min each):
  B1. Pause Syncthing for this vault
  B2. Install Self-hosted LiveSync + enable
  B3. Paste Setup URI from step A6 → Fetch from remote
  B4. Enter same E2E passphrase when asked
  B5. Install RCP-E via BRAT (same repo) OR wait for vault sync to bring plugin folder
  B6. Restart Obsidian. Confirm state folder = cursor-state

VERIFY (2 minutes):
  C1. Phone: edit a note, scroll to middle, wait 3 seconds, close Obsidian
  C2. Laptop: open Obsidian, wait for sync icon, open same note → text + scroll match
  C3. Then remove Syncthing folder for this vault on all devices

NOTES:
  - Obsidian does NOT need to be open on all devices at once.
  - Wait 2-3 seconds after scrolling before closing Obsidian on mobile (lets sync finish).
  - CouchDB laptop should be on when other devices sync (or use always-on machine).

================================================================================
"@

Set-Content -Path $cheatPath -Value $cheat -Encoding UTF8

Write-Host ''
Write-Host '========================================' -ForegroundColor Green
Write-Host ' SCRIPT DONE — automated part complete' -ForegroundColor Green
Write-Host '========================================' -ForegroundColor Green
Write-Host ''
Write-Host "Cheat sheet written to:" -ForegroundColor Cyan
Write-Host "  $cheatPath"
Write-Host ''
Write-Host 'NEXT: Open that file and follow steps A1–A8 in Obsidian on this laptop.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Quick copy for LiveSync on THIS laptop:' -ForegroundColor Cyan
Write-Host "  URI:      $localUri"
Write-Host '  User:     obsidian'
Write-Host '  Password: (what you typed)'
Write-Host '  E2E:      (what you typed)'
if ($tailscaleIp) {
    Write-Host ''
    Write-Host "Tailscale IP for phones: $tailscaleIp" -ForegroundColor Cyan
    Write-Host "  Mobile URI: $remoteUri"
}
Write-Host ''
Write-Host 'Reload Obsidian now: Ctrl+R' -ForegroundColor Green
