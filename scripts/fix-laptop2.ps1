<#
  fix-laptop2.ps1  -- RUN ON THE 2ND LAPTOP (BNG1122584X5T3).
  Repairs the half-finished downgrade: installs pinned Syncthing v2.0.11, restarts it,
  and removes the orphan "Test" folder left over from the old setup. Pure ASCII.
  RUN:  powershell -ExecutionPolicy Bypass -File .\fix-laptop2.ps1
#>
$ErrorActionPreference = 'Stop'
$sd  = "$env:LOCALAPPDATA\Syncthing"
$exe = "$sd\syncthing.exe"
$url = 'https://github.com/syncthing/syncthing/releases/download/v2.0.11/syncthing-windows-amd64-v2.0.11.zip'

Write-Host "Stopping any running Syncthing ..." -ForegroundColor Cyan
Get-Process syncthing -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

Write-Host "Downloading v2.0.11 ..." -ForegroundColor Cyan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$zip = "$env:TEMP\st2011.zip"
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
$tmp = "$env:TEMP\st2011"; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive $zip -DestinationPath $tmp -Force
$src = (Get-ChildItem $tmp -Recurse -Filter syncthing.exe | Select-Object -First 1).FullName
Copy-Item $src $exe -Force
Write-Host "  replaced exe with v2.0.11" -ForegroundColor Green

Write-Host "Starting Syncthing ..." -ForegroundColor Cyan
Start-Process -FilePath $exe -ArgumentList 'serve',"--home=$sd",'--no-browser','--allow-newer-config' -WindowStyle Hidden

$k = ([xml](Get-Content "$sd\config.xml")).configuration.gui.apikey
$H = @{ 'X-API-Key' = $k }; $b = 'http://127.0.0.1:8384/rest'
$ok = $false
foreach($i in 1..30){ Start-Sleep -Seconds 1; try { Invoke-RestMethod "$b/system/ping" -Headers $H -TimeoutSec 3 | Out-Null; $ok=$true; break } catch {} }
if(-not $ok){ Write-Host "ERROR: Syncthing did not come up" -ForegroundColor Red; exit 1 }

Write-Host "Removing orphan folders (anything that is not our Vault 515yk-rnqru) ..." -ForegroundColor Cyan
$cfg = Invoke-RestMethod "$b/config" -Headers $H
$cfg.folders | Where-Object { $_.id -ne '515yk-rnqru' } | ForEach-Object {
  Invoke-RestMethod "$b/config/folders/$($_.id)" -Method Delete -Headers $H
  Write-Host "  removed orphan folder: $($_.id) ($($_.label))" -ForegroundColor Green
}

Write-Host ""
Write-Host "version now: $((Invoke-RestMethod "$b/system/version" -Headers $H).version)" -ForegroundColor White
Write-Host "folders now: $(((Invoke-RestMethod "$b/config" -Headers $H).folders.id) -join ', ')" -ForegroundColor White
$st = Invoke-RestMethod "$b/db/status?folder=515yk-rnqru" -Headers $H
Write-Host "Vault: state=$($st.state) local=$($st.localFiles) need=$($st.needFiles) errors=$($st.errors)" -ForegroundColor White
