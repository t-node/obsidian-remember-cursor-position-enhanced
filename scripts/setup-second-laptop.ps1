<#
  setup-second-laptop.ps1
  == RUN THIS ON THE 2ND (Windows) LAPTOP -- not the master hub. ==

  Joins the 2nd laptop to the Obsidian Syncthing cluster, mirroring the hub:
    * pinned Syncthing v2.0.11 (v2.1.x has a connection-dropping bug),
    * watchdog scheduled task + firewall rules,
    * the Vault folder pre-created RECEIVE-ONLY (safe seed) with 1s watcher
      and the cluster .stignore (incl. .git / .device-id / nested conflicts / .diag).

  After it finishes it prints this laptop's DEVICE ID. Paste that back to Claude on the
  master laptop. Claude then adds + shares the Vault folder from the hub. Once it has
  seeded, run the Phase-2 one-liner Claude gives you to flip it to Send & Receive.

  HOW TO RUN (in the folder where you saved this file):
     powershell -ExecutionPolicy Bypass -File .\setup-second-laptop.ps1
  (Run as Administrator so the firewall rules can be added.)
#>
$ErrorActionPreference = 'Stop'

# ---- cluster constants (from the hub) ----
$VER     = '2.0.11'
$HUBID   = '7LN7JTC-HYK66OK-3Q4M6FE-ETNZHK6-JE43LIU-WOFPZQW-W5GZDYM-ZRXNRQD'
$FOLDER  = '515yk-rnqru'
$HOMEDIR = "$env:LOCALAPPDATA\Syncthing"
$EXE     = "$HOMEDIR\syncthing.exe"
$GUI     = 'http://127.0.0.1:8384'

$IGNORES = @(
  '(?d)*.sync-conflict-*'
  '(?d)**/*.sync-conflict-*'
  '(?d)/.git'
  '(?d)/.stversions'
  '(?d)/cursor-state/.diag-*'
  '/.obsidian/workspace.json'
  '/.obsidian/workspace-mobile.json'
  '/.obsidian/workspace.json.bak'
  '/.obsidian/plugins/obsidian-livesync/data.json'
  '/.obsidian/plugins/remember-cursor-position-enhanced/.device-id.local.json'
  '(?d)/.obsidian/**/*.log'
  '/rcp-enhanced-logs'
  '/sync-health'
  '/.trash'
)

function Say([AllowEmptyString()][string]$m, [string]$c='Gray'){ Write-Host $m -ForegroundColor $c }

# ---- 1. find / confirm the Obsidian vault on this laptop ----
Say "STEP 1/6  Locate this laptop's Obsidian vault." Cyan
Say "  (It is the folder that contains a .obsidian sub-folder: your existing vault copy.)"
$vault = Read-Host "  Paste the full path to the vault on THIS laptop"
$vault = $vault.Trim('"').Trim()
if (-not (Test-Path (Join-Path $vault '.obsidian'))) {
  Say "  WARNING: no .obsidian folder found under '$vault'." Yellow
  if ((Read-Host "  Use it anyway? (y/N)") -ne 'y') { Say "Aborted." Red; exit 1 }
}
Say "  Using vault: $vault" Green

# ---- 2. download + stage pinned Syncthing ----
Say "STEP 2/6  Install Syncthing v$VER ..." Cyan
New-Item -ItemType Directory -Path $HOMEDIR -Force | Out-Null
if (-not (Test-Path $EXE)) {
  $zip = "$env:TEMP\syncthing-$VER.zip"
  $url = "https://github.com/syncthing/syncthing/releases/download/v$VER/syncthing-windows-amd64-v$VER.zip"
  Say "  downloading $url"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
  $tmp = "$env:TEMP\st-$VER"; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive $zip -DestinationPath $tmp -Force
  $found = Get-ChildItem $tmp -Recurse -Filter syncthing.exe | Select-Object -First 1
  Copy-Item $found.FullName $EXE -Force
  Say "  installed -> $EXE" Green
} else { Say "  already present -> $EXE" Green }

# ---- 3. generate config (device cert + api key) ----
Say "STEP 3/6  Generate config + device identity ..." Cyan
& $EXE generate --home="$HOMEDIR" *> $null
# (generate already binds the GUI to 127.0.0.1:8384 by default)

# ---- 4. start it (matches hub launch) + wait for REST ----
Say "STEP 4/6  Start Syncthing ..." Cyan
if (-not (Get-Process syncthing -ErrorAction SilentlyContinue)) {
  Start-Process -FilePath $EXE -ArgumentList "serve","--home=$HOMEDIR","--no-browser","--allow-newer-config" -WindowStyle Hidden
}
$apikey = $null
foreach($i in 1..30){
  Start-Sleep -Seconds 1
  try { $apikey = ([xml](Get-Content "$HOMEDIR\config.xml")).configuration.gui.apikey } catch {}
  if ($apikey) {
    try { Invoke-RestMethod "$GUI/rest/system/ping" -Headers @{'X-API-Key'=$apikey} -TimeoutSec 3 | Out-Null; break } catch {}
  }
}
if (-not $apikey) { Say "ERROR: Syncthing REST did not come up." Red; exit 1 }
$H = @{ 'X-API-Key'=$apikey; 'Content-Type'='application/json' }
$myID = (Invoke-RestMethod "$GUI/rest/system/status" -Headers $H).myID
Say "  REST up. This laptop device ID: $myID" Green

# ---- 5. configure: add hub device + Vault folder (RECEIVE-ONLY) + ignores ----
Say "STEP 5/6  Configure device + Vault folder (Receive-Only seed) ..." Cyan
$dev = @{ deviceID=$HUBID; name='DESKTOP-VVTRBNG-hub'; addresses=@('dynamic') } | ConvertTo-Json
Invoke-RestMethod "$GUI/rest/config/devices/$HUBID" -Method Put -Headers $H -Body $dev | Out-Null
$folderObj = @{
  id=$FOLDER; label='Vault'; path=$vault; type='receiveonly'
  fsWatcherEnabled=$true; fsWatcherDelayS=1
  devices=@(@{deviceID=$myID}, @{deviceID=$HUBID})
  versioning=@{ type='staggered'; params=@{ maxAge='2592000' } }
} | ConvertTo-Json -Depth 6
Invoke-RestMethod "$GUI/rest/config/folders/$FOLDER" -Method Put -Headers $H -Body $folderObj | Out-Null
$ign = @{ ignore=$IGNORES } | ConvertTo-Json
Invoke-RestMethod "$GUI/rest/db/ignores?folder=$FOLDER" -Method Post -Headers $H -Body $ign | Out-Null
Say "  device + folder + ignores set." Green

# ---- 6. firewall + watchdog (so it auto-runs like the hub) ----
Say "STEP 6/6  Firewall + watchdog ..." Cyan
try {
  New-NetFirewallRule -DisplayName "Syncthing (exe)" -Direction Inbound -Program $EXE -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
  New-NetFirewallRule -DisplayName "Syncthing 22000 TCP" -Direction Inbound -Protocol TCP -LocalPort 22000 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
  New-NetFirewallRule -DisplayName "Syncthing 22000 UDP" -Direction Inbound -Protocol UDP -LocalPort 22000 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null
  Say "  firewall rules added." Green
} catch { Say "  (could not add firewall rules: re-run as Administrator if peers cannot connect)" Yellow }

$watch = "$HOMEDIR\watch-syncthing.ps1"
@"
`$exe='$EXE'
if (-not (Test-Path `$exe)) { exit 1 }
if (Get-Process syncthing -ErrorAction SilentlyContinue) { exit 0 }
Start-Process -FilePath `$exe -ArgumentList 'serve','--home=$HOMEDIR','--no-browser','--allow-newer-config' -WindowStyle Hidden
"@ | Set-Content -Path $watch -Encoding UTF8
try {
  $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source; if(-not $pwshExe){ $pwshExe='powershell.exe' }
  $action  = New-ScheduledTaskAction -Execute $pwshExe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watch`""
  $trig1   = New-ScheduledTaskTrigger -AtLogOn
  $trig2   = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)
  $princ   = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  Register-ScheduledTask -TaskName "ObsidianSyncthing" -Action $action -Trigger $trig1,$trig2 -Principal $princ -Settings $set -Force | Out-Null
  Say "  watchdog task 'ObsidianSyncthing' registered." Green
} catch { Say "  (could not register watchdog task: $($_.Exception.Message))" Yellow }

Say " "
Say "============================================================" Green
Say "  DONE (Phase 1). Send this DEVICE ID to Claude:" Green
Write-Host "    $myID" -ForegroundColor White
Say "============================================================" Green
Say "  Claude shares the Vault folder from the hub; this laptop then"
Say "  seeds Receive-Only. After it shows 100%, run the Phase-2"
Say "  one-liner Claude gives you to switch it to Send & Receive."
