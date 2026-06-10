# Shared config loader. Dot-source this AFTER a script's param() block:  . "$PSScriptRoot\_sync-config.ps1"
# It fills any sync variable the caller didn't set from sync.config.ps1 (gitignored, your real values),
# falling back to sync.config.example.ps1 (placeholders). This keeps secrets OUT of the committed scripts.
$cfgLocal   = Join-Path $PSScriptRoot 'sync.config.ps1'
$cfgExample = Join-Path $PSScriptRoot 'sync.config.example.ps1'
if (Test-Path $cfgLocal) { . $cfgLocal }
elseif (Test-Path $cfgExample) { . $cfgExample; Write-Host "WARNING: no scripts\sync.config.ps1 -- using example placeholders. Copy sync.config.example.ps1 to sync.config.ps1 and fill in your values." -ForegroundColor Yellow }
else { throw "Missing scripts\sync.config.ps1 (copy it from scripts\sync.config.example.ps1)." }

# Fill only what the caller left empty (so explicit -Param overrides still win).
if (-not $CouchUrl)     { $CouchUrl     = $SyncConfig.CouchUrl }
if (-not $TailscaleUrl) { $TailscaleUrl = $SyncConfig.TailscaleUrl }
if (-not $CouchUser)    { $CouchUser    = $SyncConfig.CouchUser }
if (-not $CouchPass)    { $CouchPass    = $SyncConfig.CouchPass }
if (-not $DbName)       { $DbName       = $SyncConfig.DbName }
if (-not $VaultDir)     { $VaultDir     = $SyncConfig.VaultDir }
if (-not $LaptopVault)  { $LaptopVault  = $SyncConfig.VaultDir }
if (-not $Android)      { $Android      = $SyncConfig.Devices }
if (-not $Devices)      { $Devices      = $SyncConfig.Devices }
