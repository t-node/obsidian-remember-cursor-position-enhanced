<#
.SYNOPSIS
  One command to (a) turn deep sync logging ON across every connected device, and (b) COLLECT all the
  cursor-sync diagnostics from the whole fleet into one timestamped folder for a post-mortem.

.DESCRIPTION
  The plugin writes two kinds of logs:
    1. cursor-state/.diag-{deviceId}.json  — bounded, de-duped, high-signal event log that SYNCS between
       devices. So every device's diag shows up in every vault. This is the primary forensic record
       (force-pushed / force-outranked / apply-rejected / cross-device applies, each with the full
       candidate list: every device's lastModified / scroll / revision / authority / forcedAt).
    2. rcp-enhanced-logs/{Device}-{id}.log — verbose per-device trace, NOT synced (pulled via adb/USB).

  Typical use when you hit the "it reverted to an old state" issue:
    - Today (one-time): pwsh scripts/sync-debug.ps1 -EnableLogging   # with phone/2nd-laptop connected
    - After it happens : connect all devices, then: pwsh scripts/sync-debug.ps1 -Collect
      -> hands you debug-reports/rcpe-sync-<timestamp>/ with everything + a summary to share with Claude.

.EXAMPLE
  pwsh scripts/sync-debug.ps1 -EnableLogging
  pwsh scripts/sync-debug.ps1 -Collect
  pwsh scripts/sync-debug.ps1 -DisableLogging
#>
[CmdletBinding()]
param(
    [switch]$EnableLogging,
    [switch]$DisableLogging,
    [switch]$Collect
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$pluginSub = '.obsidian/plugins/remember-cursor-position-enhanced'

# Fleet (mirrors scripts/deploy-all.ps1). Laptops are filesystem paths; Android via adb serial.
$laptopVaults = @(
    @{ Label = 'this-laptop-vyovb870'; Vault = ($env:OBSIDIAN_VAULT_DIR ?? 'C:\notes1') }
)
$androidTargets = @(
    @{ Label = 'phone-hvmodycj';  Serial = 'RZCY11EKL7E'; Vault = '/storage/emulated/0/Documents/Test'; Pkg = 'md.obsidian' },
    @{ Label = 'tablet-bri9e1q4'; Serial = 'R9ZY90L2DVM'; Vault = '/storage/emulated/0/ObsidianVault';  Pkg = 'md.obsidian' }
)

$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adb)) { $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source }

function Get-ConnectedSerials {
    if (-not $adb) { return @() }
    return (& $adb devices) | Where-Object { $_ -match '\sdevice$' } | ForEach-Object { ($_ -split '\s+')[0] }
}

# Flip ONLY the debugLogging + logToFile keys (leave every other setting untouched).
function Set-LoggingFlags([string]$content, [bool]$on) {
    $v = $on ? 'true' : 'false'
    $content = $content -replace '("debugLogging":\s*)(true|false)', "`${1}$v"
    $content = $content -replace '("logToFile":\s*)(true|false)', "`${1}$v"
    return $content
}

if ($EnableLogging -or $DisableLogging) {
    $on = [bool]$EnableLogging
    Write-Host ("== {0} deep sync logging ==" -f ($on ? 'ENABLING' : 'DISABLING')) -ForegroundColor Cyan

    foreach ($l in $laptopVaults) {
        $dj = Join-Path $l.Vault "$pluginSub/data.json"
        if (-not (Test-Path $dj)) { Write-Host "  SKIP  $($l.Label): no data.json" -ForegroundColor DarkGray; continue }
        $c = Get-Content $dj -Raw
        Set-LoggingFlags $c $on | Set-Content $dj -NoNewline
        Write-Host "  OK    $($l.Label) (reload Obsidian: Ctrl+R)" -ForegroundColor Green
    }

    $connected = Get-ConnectedSerials
    foreach ($t in $androidTargets) {
        if ($connected -notcontains $t.Serial) { Write-Host "  SKIP  $($t.Label): not connected" -ForegroundColor DarkGray; continue }
        $remote = "$($t.Vault)/$pluginSub/data.json"
        # Edits only stick while Obsidian is CLOSED; force-stop first, never relaunch via adb.
        & $adb -s $t.Serial shell am force-stop $t.Pkg | Out-Null
        $tmp = Join-Path $env:TEMP "rcpe-data-$($t.Serial).json"
        & $adb -s $t.Serial pull $remote $tmp | Out-Null
        if (-not (Test-Path $tmp)) { Write-Host "  FAIL  $($t.Label): could not pull data.json" -ForegroundColor Red; continue }
        $c = Get-Content $tmp -Raw
        $patched = Set-LoggingFlags $c $on
        try { $patched | ConvertFrom-Json | Out-Null } catch { Write-Host "  FAIL  $($t.Label): patched JSON invalid, leaving as-is" -ForegroundColor Red; continue }
        $patched | Set-Content $tmp -NoNewline
        & $adb -s $t.Serial push $tmp $remote | Out-Null
        Remove-Item $tmp -Force
        Write-Host "  OK    $($t.Label) (reopen Obsidian by tapping the icon)" -ForegroundColor Green
    }
    Write-Host "`nDone. Reload/reopen each device so the new flags take effect." -ForegroundColor Cyan
}

if ($Collect) {
    Write-Host "== Collecting cursor-sync diagnostics from the fleet ==" -ForegroundColor Cyan
    # Stamp the folder from the filesystem (script can't use Get-Date for naming reproducibly, but here
    # a wall-clock name is fine and helpful).
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $outDir = Join-Path $repoRoot "debug-reports/rcpe-sync-$stamp"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    # 1. Synced .diag-*.json — present in EVERY vault, so grab them from the laptop (all devices' come home).
    foreach ($l in $laptopVaults) {
        $cs = Join-Path $l.Vault 'cursor-state'
        if (Test-Path $cs) {
            $dest = Join-Path $outDir "synced-diags"
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            # New name `{deviceId}.diag.json` (syncs home) + legacy `.diag-*.json` (local only).
            Get-ChildItem $cs -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*.diag.json' -or $_.Name -like '.diag-*.json' } | ForEach-Object {
                Copy-Item $_.FullName (Join-Path $dest $_.Name) -Force
            }
            # The device store files too — they show the CURRENT positions + authority tiers.
            Get-ChildItem $cs -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.diag-*' } | ForEach-Object {
                Copy-Item $_.FullName (Join-Path $dest $_.Name) -Force
            }
        }
        # Laptop verbose log.
        $logDir = Join-Path $l.Vault 'rcp-enhanced-logs'
        if (Test-Path $logDir) {
            $dest = Join-Path $outDir "logs-$($l.Label)"
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Get-ChildItem $logDir -Filter '*.log' -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item $_.FullName (Join-Path $dest $_.Name) -Force }
        }
    }

    # 2. Each connected Android device: pull its verbose logs + its own local diag (in case sync lags).
    $connected = Get-ConnectedSerials
    foreach ($t in $androidTargets) {
        if ($connected -notcontains $t.Serial) { Write-Host "  (not connected, skipped: $($t.Label))" -ForegroundColor DarkGray; continue }
        $dest = Join-Path $outDir "logs-$($t.Label)"
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        & $adb -s $t.Serial pull "$($t.Vault)/rcp-enhanced-logs" $dest 2>$null | Out-Null
        & $adb -s $t.Serial pull "$($t.Vault)/cursor-state" (Join-Path $dest 'cursor-state') 2>$null | Out-Null
        Write-Host "  OK    pulled $($t.Label)" -ForegroundColor Green
    }

    # 3. Quick summary across all synced diags so the headline is obvious before deep analysis.
    $summary = Join-Path $outDir 'SUMMARY.txt'
    "RCP-E cursor-sync diagnostic collection $stamp" | Set-Content $summary
    "" | Add-Content $summary
    $diagDir = Join-Path $outDir 'synced-diags'
    if (Test-Path $diagDir) {
        foreach ($f in (Get-ChildItem $diagDir -Force | Where-Object { $_.Name -like '*.diag.json' -or $_.Name -like '.diag-*.json' })) {
            try {
                $d = Get-Content $f.FullName -Raw | ConvertFrom-Json
                $ev = $d.events
                $counts = $ev | Group-Object event | ForEach-Object { "$($_.Name)=$($_.Count)" }
                "[$($f.Name)]  events=$($ev.Count)  ($($counts -join ', '))" | Add-Content $summary
                $ev | Where-Object { $_.event -eq 'force-outranked' } | ForEach-Object {
                    "    !! force-outranked @ $($_.ts): forced=$($_.forcedDeviceId) lost to winner=$($_.winnerDeviceId) skewMs=$($_.skewMs) note=$($_.notePath)" | Add-Content $summary
                }
            } catch { "[$($f.Name)]  (unreadable: $_)" | Add-Content $summary }
        }
    }
    Write-Host "`nCollected to: $outDir" -ForegroundColor Green
    Write-Host "Summary:" -ForegroundColor Cyan
    Get-Content $summary | Write-Host
    Write-Host "`nTell Claude: 'verify the logs in $outDir'." -ForegroundColor Cyan
}

if (-not ($EnableLogging -or $DisableLogging -or $Collect)) {
    Write-Host "Usage: pwsh scripts/sync-debug.ps1 [-EnableLogging | -DisableLogging | -Collect]" -ForegroundColor Yellow
}
