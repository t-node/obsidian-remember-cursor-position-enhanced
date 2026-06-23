# Registers ObsidianSyncthing: keeps the Syncthing hub running (logon + every 15 min).
$ErrorActionPreference = "Stop"
$out = "C:\obsidian-remember-cursor-position\scripts\_install_syncthing_task.out.txt"
function W($m){ Add-Content -Path $out -Value $m; Write-Host $m }
Set-Content -Path $out -Value "=== install ObsidianSyncthing @ $(Get-Date -Format o) ==="

$script = "C:\obsidian-remember-cursor-position\scripts\start-syncthing.ps1"
$pwsh = (Get-Command pwsh).Source
$me = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$timeTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName "ObsidianSyncthing" -Action $action -Trigger $timeTrigger,$logonTrigger -Principal $principal -Settings $settings -Description "Keep the Syncthing hub running for the Obsidian vault. See SYNCTHING-MIGRATION.md." -Force | Out-Null
$t = Get-ScheduledTask -TaskName "ObsidianSyncthing"
W "Registered ObsidianSyncthing (logon + 15 min). State=$($t.State)"
W "=== done ==="
