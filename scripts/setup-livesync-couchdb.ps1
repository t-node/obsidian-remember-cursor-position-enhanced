#Requires -Version 5.1
<#
.SYNOPSIS
  Start CouchDB for Obsidian Self-hosted LiveSync and create the vault database.

.DESCRIPTION
  Run on the always-on laptop (Docker required). Mobile devices reach CouchDB via Tailscale IP.

.PARAMETER Password
  CouchDB password for user "obsidian". Prompted if omitted.

.PARAMETER Database
  CouchDB database name (default: obsidian-vault).

.EXAMPLE
  .\setup-livesync-couchdb.ps1
#>
param(
    [string]$Password,
    [string]$Database = 'obsidian-vault'
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ComposeDir = Join-Path $ScriptDir 'livesync'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is not installed or not on PATH. Install Docker Desktop first."
}

if (-not $Password) {
    $Password = Read-Host 'CouchDB password for user obsidian (min 8 chars)'
}
if ($Password.Length -lt 8) {
    Write-Error 'Password must be at least 8 characters.'
}

$env:COUCHDB_PASSWORD = $Password
Push-Location $ComposeDir
try {
    docker compose up -d --force-recreate
    Write-Host "Waiting for CouchDB..." -ForegroundColor Cyan
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
        Write-Error 'CouchDB did not become ready. Check: docker compose logs'
    }

    $pair = "obsidian:$Password"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $basic = [Convert]::ToBase64String($bytes)
    $headers = @{ Authorization = "Basic $basic" }

    $dbUrl = "http://127.0.0.1:5984/$Database"
    try {
        Invoke-RestMethod -Uri $dbUrl -Method Put -Headers $headers | Out-Null
        Write-Host "Created database: $Database" -ForegroundColor Green
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 412) {
            Write-Host "Database already exists: $Database" -ForegroundColor Yellow
        } else {
            throw
        }
    }

    Write-Host ''
    Write-Host '=== CouchDB is ready ===' -ForegroundColor Green
    Write-Host "  Local URL:    http://127.0.0.1:5984"
    Write-Host "  Database:     $Database"
    Write-Host "  Username:     obsidian"
    Write-Host "  Password:     (what you entered)"
    Write-Host ''
    Write-Host 'Next — Tailscale (all 4 devices):' -ForegroundColor Cyan
    Write-Host '  1. Install Tailscale on each device; sign in to the same account.'
    Write-Host '  2. On this laptop run: tailscale ip -4'
    Write-Host '  3. Mobile CouchDB URI: https://<tailscale-ip>:5984  (or http if LAN only)'
    Write-Host ''
    Write-Host 'Next — Obsidian master laptop (complete vault):' -ForegroundColor Cyan
    Write-Host '  1. Pause Syncthing for this vault folder.'
    Write-Host '  2. Community plugins → Self-hosted LiveSync → enable.'
    Write-Host '  3. LiveSync settings → Connect → URI:'
    Write-Host "     http://127.0.0.1:5984/$Database"
    Write-Host '  4. User: obsidian, Password: (above), E2E passphrase: choose one — same on all devices.'
    Write-Host '  5. Sync mode: LiveSync. First run: Overwrite remote with local.'
    Write-Host '  6. Settings → Copy setup URI → paste on other 3 devices → Fetch from remote.'
    Write-Host ''
    Write-Host 'RCP-E (all devices):' -ForegroundColor Cyan
    Write-Host '  BRAT → remember-cursor-position-enhanced v2.1.0+'
    Write-Host '  State folder should be: cursor-state/ (default; migrates automatically)'
    Write-Host '  Settings → Files & links → Excluded files → add: cursor-state/'
    Write-Host ''
    Write-Host 'Verify: edit a note on phone → open same note on laptop within ~1–3s → cursor/scroll match.' -ForegroundColor Green
} finally {
    Pop-Location
}
