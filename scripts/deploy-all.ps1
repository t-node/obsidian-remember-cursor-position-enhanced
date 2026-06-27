<#
.SYNOPSIS
  Build the plugin once and deploy main.js + manifest.json to ALL devices in the 4-device fleet,
  over the network where possible — ideally one shot, nothing plugged in.

.DESCRIPTION
  Plugin CODE is excluded from Syncthing (.stignore), so each device is deployed individually. This
  script reaches them every way it can, best-effort, skipping whatever isn't reachable:

    - This laptop                -> file copy
    - plugin-dist/ (Syncthing)   -> file copy into the synced delivery folder (reaches EVERY device,
                                    incl. the office laptop, with no connection; plugin self-installs it)
    - Phone + Tablet             -> adb push, over Tailscale (wireless adb) or USB — instant
    - 2nd (office) laptop        -> Syncthing plugin-dist/ ONLY (corporate machine; no server on it)

  Phone/Tablet wireless adb needs ONE-TIME setup (then automatic): plug into USB once and run
  scripts/adb-net.ps1 -Enable. Tailscale IPs live in scripts/sync.config.ps1 (gitignored).

  It NEVER relaunches Obsidian (that has blanked the mobile config before) — it force-stops so the new
  code loads on the next manual open/reload.

.EXAMPLE
  pwsh scripts/deploy-all.ps1                 # build + deploy everywhere reachable
  pwsh scripts/deploy-all.ps1 -SkipBuild      # reuse the current main.js
  pwsh scripts/deploy-all.ps1 -NoWireless     # USB-only for Android (skip Tailscale adb)
#>
# -Adb is opt-in: also push to phone/tablet over adb (instant). Default is Syncthing-only (plugin-dist).
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$NoForceStop,
    [switch]$NoWireless,
    [switch]$Adb,
    [switch]$VerifyOnly,
    [string[]]$LaptopPluginDir = @()
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$files = @('main.js', 'manifest.json', 'LICENSE')
$pluginSubdir = '.obsidian/plugins/remember-cursor-position-enhanced'

# Verify a copied file matches the source byte-for-byte (MD5). Returns $true/$false.
function Test-SameFile([string]$a, [string]$b) {
    if (-not (Test-Path $a) -or -not (Test-Path $b)) { return $false }
    return (Get-FileHash $a -Algorithm MD5).Hash -eq (Get-FileHash $b -Algorithm MD5).Hash
}
$srcMain = Join-Path $repoRoot 'main.js'

# Optional config (Tailscale IPs + 2nd-laptop SSH target). Loaded defensively so deploy works without it.
$SyncConfig = $null
$cfgPath = Join-Path $PSScriptRoot 'sync.config.ps1'
if (Test-Path $cfgPath) { . $cfgPath }

# --- The fleet -------------------------------------------------------------------------------------
$laptopTargets = @(
    @{ Label = 'this laptop (vyovb870)'; Dir = ($env:OBSIDIAN_VAULT_PLUGIN_DIR ?? 'C:\notes1\.obsidian\plugins\remember-cursor-position-enhanced') }
)
foreach ($d in $LaptopPluginDir) { $laptopTargets += @{ Label = "laptop (extra)"; Dir = $d } }

# Android targets: USB serial + Tailscale IP (for wireless adb). IPs come from config if present.
function Get-DeviceIp([string]$name, [string]$fallback) {
    if ($SyncConfig -and $SyncConfig.Devices) {
        $m = $SyncConfig.Devices | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if ($m -and $m.ip) { return $m.ip }
    }
    return $fallback
}
$androidTargets = @(
    @{ Label = 'phone (hvmodycj)';  Serial = 'RZCY11EKL7E'; Ip = (Get-DeviceIp 'phone' '100.96.229.92'); Vault = '/storage/emulated/0/Documents/Test'; Pkg = 'md.obsidian' },
    @{ Label = 'tablet (bri9e1q4)'; Serial = 'R9ZY90L2DVM'; Ip = (Get-DeviceIp 'tablet' '100.93.19.49'); Vault = '/storage/emulated/0/ObsidianVault'; Pkg = 'md.obsidian' }
)

$adbExe = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if (-not (Test-Path $adbExe)) { $adbExe = (Get-Command adb -ErrorAction SilentlyContinue).Source }

# --- Build -----------------------------------------------------------------------------------------
if ($SkipBuild -or $VerifyOnly) {
    Write-Host '== Skipping build (using existing main.js) ==' -ForegroundColor Yellow
} else {
    Write-Host '== Building plugin ==' -ForegroundColor Cyan
    Push-Location $repoRoot
    try { npm run build } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw 'Build failed — aborting deploy.' }
}
foreach ($f in $files) {
    if (-not (Test-Path (Join-Path $repoRoot $f))) { throw "Missing $f in repo — build may have failed." }
}

$results = [System.Collections.Generic.List[object]]::new()

if (-not $VerifyOnly) {
# --- Laptops (file copy + verify) ------------------------------------------------------------------
Write-Host "`n== Laptops ==" -ForegroundColor Cyan
foreach ($t in $laptopTargets) {
    $dir = $t.Dir
    $parentVault = Split-Path (Split-Path (Split-Path $dir))
    if (-not (Test-Path $parentVault)) {
        Write-Host "  SKIP  $($t.Label): not reachable ($parentVault not found)" -ForegroundColor DarkGray
        $results.Add(@{ Device = $t.Label; Status = 'skipped (not reachable)' }); continue
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in $files) { Copy-Item (Join-Path $repoRoot $f) (Join-Path $dir $f) -Force }
    # Verify the bytes actually landed (not just that Copy-Item didn't throw).
    if (Test-SameFile (Join-Path $dir 'main.js') $srcMain) {
        Write-Host "  OK    $($t.Label) -> $dir  [verified ✓]" -ForegroundColor Green
        $results.Add(@{ Device = $t.Label; Status = 'deployed + verified ✓' })
    } else {
        Write-Host "  FAIL  $($t.Label): copied file does NOT match source!" -ForegroundColor Red
        $results.Add(@{ Device = $t.Label; Status = 'FAILED (verify mismatch)' })
    }
}

# --- Syncthing auto-delivery (universal fallback — reaches EVERY device with no connection) ---------
Write-Host "`n== Syncthing delivery (plugin-dist/) ==" -ForegroundColor Cyan
$masterVault = Split-Path (Split-Path (Split-Path $laptopTargets[0].Dir))
if (Test-Path $masterVault) {
    $distDir = Join-Path $masterVault 'plugin-dist'
    New-Item -ItemType Directory -Force -Path $distDir | Out-Null
    foreach ($f in @('main.js', 'manifest.json')) { Copy-Item (Join-Path $repoRoot $f) (Join-Path $distDir $f) -Force }
    # Ship the double-click helpers alongside it, so a device with no adb/SSH (e.g. the office laptop)
    # can self-install the build (install-here.cmd) and set its Syncthing watcher delay for fast sync
    # (set-watcher-here.cmd/.ps1) — both reach it through this synced folder.
    foreach ($helper in @('install-here.cmd', 'set-watcher-here.cmd', 'set-watcher-here.ps1')) {
        $src = Join-Path $PSScriptRoot $helper
        if (Test-Path $src) { Copy-Item $src (Join-Path $distDir $helper) -Force }
    }
    if (Test-SameFile (Join-Path $distDir 'main.js') $srcMain) {
        Write-Host "  OK    -> $distDir  [verified ✓]  (Syncthing carries this to every device)" -ForegroundColor Green
        $results.Add(@{ Device = 'plugin-dist (all via sync)'; Status = 'delivered + verified ✓' })
    } else {
        Write-Host "  FAIL  plugin-dist copy does NOT match source!" -ForegroundColor Red
        $results.Add(@{ Device = 'plugin-dist'; Status = 'FAILED (verify mismatch)' })
    }
} else {
    Write-Host "  SKIP  master vault not found ($masterVault)" -ForegroundColor DarkGray
}

# --- Android (adb push, over Tailscale wireless or USB) — OPT-IN with -Adb -------------------------
# By default we DON'T touch adb: the phone + tablet already get the build via plugin-dist (Syncthing),
# so there's no "not connected" noise. Pass -Adb (with a device plugged in or wireless-adb enabled) to
# also push instantly — handy for the one-time bootstrap onto a self-updating build.
Write-Host "`n== Android ==" -ForegroundColor Cyan
if (-not $Adb) {
    Write-Host '  via Syncthing plugin-dist/ — self-installs on next open. (Pass -Adb for an instant push.)' -ForegroundColor Green
    $results.Add(@{ Device = 'phone + tablet'; Status = 'via plugin-dist sync' })
} elseif (-not $adbExe) {
    Write-Host '  adb not found — skipping phone + tablet.' -ForegroundColor Yellow
    foreach ($t in $androidTargets) { $results.Add(@{ Device = $t.Label; Status = 'skipped (no adb)' }) }
} else {
    if (-not $NoWireless) {
        # Reconnect to known Tailscale IPs (no USB). Needs a one-time `adb-net.ps1 -Enable` per device;
        # tcpip mode resets on reboot, so a rebooted device silently won't connect (USB re-enable then).
        foreach ($t in $androidTargets) {
            if ($t.Ip) { & $adbExe connect "$($t.Ip):5555" 2>&1 | Out-Null }
        }
    }
    $connected = (& $adbExe devices) | Where-Object { $_ -match '\sdevice$' } | ForEach-Object { ($_ -split '\s+')[0] }
    foreach ($t in $androidTargets) {
        # Use whichever transport is live: USB serial or the wireless ip:5555 id.
        $adbId = @($t.Serial, "$($t.Ip):5555") | Where-Object { $connected -contains $_ } | Select-Object -First 1
        if (-not $adbId) {
            Write-Host "  SKIP  $($t.Label): not connected (USB $($t.Serial) / wireless $($t.Ip):5555)" -ForegroundColor DarkGray
            $results.Add(@{ Device = $t.Label; Status = 'skipped (not connected)' }); continue
        }
        $via = if ($adbId -match ':\d+$') { 'Tailscale' } else { 'USB' }
        $remoteDir = "$($t.Vault)/$pluginSubdir"
        if (-not $NoForceStop) { & $adbExe -s $adbId shell am force-stop $t.Pkg | Out-Null }
        & $adbExe -s $adbId shell mkdir -p "`"$remoteDir`"" | Out-Null
        $pushOk = $true
        foreach ($f in $files) {
            & $adbExe -s $adbId push (Join-Path $repoRoot $f) "$remoteDir/$f" | Out-Null
            if ($LASTEXITCODE -ne 0) { $pushOk = $false }
        }
        # Verify ON THE DEVICE that main.js really matches (md5), not just that push returned 0.
        $localMd5 = (Get-FileHash $srcMain -Algorithm MD5).Hash.ToLower()
        $remoteMd5 = ((& $adbExe -s $adbId shell "md5sum `"$remoteDir/main.js`"" 2>$null) -split '\s+')[0]
        $verified = $remoteMd5 -and ($remoteMd5.ToLower() -eq $localMd5)
        if ($pushOk -and $verified) {
            Write-Host "  OK    $($t.Label) via $via -> $remoteDir  [verified ✓ on device]" -ForegroundColor Green
            $results.Add(@{ Device = "$($t.Label) [$via]"; Status = 'deployed + verified ✓ (reopen Obsidian)' })
        } elseif ($pushOk) {
            Write-Host "  WARN  $($t.Label): pushed but on-device md5 didn't confirm (got '$remoteMd5')" -ForegroundColor Yellow
            $results.Add(@{ Device = "$($t.Label) [$via]"; Status = 'pushed, NOT verified' })
        } else {
            Write-Host "  FAIL  $($t.Label): adb push error" -ForegroundColor Red
            $results.Add(@{ Device = $t.Label; Status = 'FAILED (adb push)' })
        }
    }
}

# --- 2nd laptop (office, managed) -----------------------------------------------------------------
# No SSH/remote push here on purpose: it's a corporate machine, so we DON'T run a server on it. It gets
# the build purely through the synced plugin-dist/ folder above; its plugin self-installs on next open.
Write-Host "`n== 2nd laptop (office) ==" -ForegroundColor Cyan
Write-Host '  via Syncthing plugin-dist/ (no SSH on the corporate machine) — self-installs on next open.' -ForegroundColor Green
$results.Add(@{ Device = '2nd laptop (office)'; Status = 'via plugin-dist sync' })
}  # end if (-not $VerifyOnly)

# --- Verify which devices are actually RUNNING this build (via synced running-{deviceId}.json acks) -
# Each device's plugin writes its running build's UTF-8 byte size to plugin-dist/running-*.json, which
# syncs home. main.js on disk here is that same byte size, so we can confirm — even for devices we
# never connect — exactly which ones are live on the build we just shipped, and which are still behind.
Write-Host "`n== Live-on-device verification (synced acks) ==" -ForegroundColor Cyan
$expectedBytes = (Get-Item $srcMain).Length
$distDir2 = Join-Path (Split-Path (Split-Path (Split-Path $laptopTargets[0].Dir))) 'plugin-dist'
$acks = @(if (Test-Path $distDir2) { Get-ChildItem $distDir2 -Filter 'running-*.json' -ErrorAction SilentlyContinue })
if (-not $acks -or $acks.Count -eq 0) {
    Write-Host '  (no running-acks yet — they appear once each device opens Obsidian on this build and syncs back)' -ForegroundColor DarkGray
} else {
    foreach ($a in $acks) {
        try {
            $j = Get-Content $a.FullName -Raw | ConvertFrom-Json
            $live = ($j.bytes -eq $expectedBytes)
            $ageMin = [int](([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [int64]$j.ts) / 60000)
            $mark = if ($live) { 'RUNNING current ✓' } else { "behind (running v$($j.version), $($j.bytes)B vs $($expectedBytes)B)" }
            $color = if ($live) { 'Green' } else { 'Yellow' }
            Write-Host ("  {0,-22} {1}  (acked {2}m ago)" -f $j.deviceName, $mark, $ageMin) -ForegroundColor $color
        } catch { Write-Host "  (unreadable ack: $($a.Name))" -ForegroundColor DarkGray }
    }
    Write-Host '  Tip: rerun  pwsh scripts/deploy-all.ps1 -VerifyOnly  after reopening devices to watch them flip to ✓.' -ForegroundColor DarkGray
}

# --- Summary ---------------------------------------------------------------------------------------
Write-Host "`n== Summary ==" -ForegroundColor Cyan
foreach ($r in $results) { Write-Host ("  {0,-30} {1}" -f $r.Device, $r.Status) }
if (-not $VerifyOnly) {
    Write-Host "`nReload to pick up the new build:" -ForegroundColor Cyan
    Write-Host '  - Desktop: Ctrl+R   - Mobile: reopen Obsidian by tapping the icon (not via adb)'
}
