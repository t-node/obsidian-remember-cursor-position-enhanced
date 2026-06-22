# Registers the ObsidianCouchBridge scheduled task: runs sync-couch-bridge.ps1
# at logon and every 30 minutes, elevated (needed for netsh portproxy).
$ErrorActionPreference = "Stop"
$out = "C:\obsidian-remember-cursor-position\scripts\_install_bridge_task.out.txt"
function W($m){ Add-Content -Path $out -Value $m; Write-Host $m }
Set-Content -Path $out -Value "=== install @ $(Get-Date -Format o) ==="

$script = "C:\obsidian-remember-cursor-position\scripts\sync-couch-bridge.ps1"
$pwsh = (Get-Command pwsh).Source
$taskName = "ObsidianCouchBridge"
$me = "$env:USERDOMAIN\$env:USERNAME"

$action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

# Two triggers (mirrors the working ObsidianSyncHistory pattern):
#  - a TIME trigger that repeats every 30 min indefinitely (continuous self-heal), and
#  - an AtLogon trigger (immediate fix right after a reboot, before the 30-min tick).
$timeTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30)
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn

$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $timeTrigger, $logonTrigger -Principal $principal -Settings $settings -Description "Keep Windows->WSL CouchDB bridge (port 5994) alive for Obsidian LiveSync. See SYNC-RUNBOOK.md." -Force | Out-Null
W "Registered task '$taskName' for $me (RunLevel Highest)."

$t = Get-ScheduledTask -TaskName $taskName
W ("State={0}  Triggers={1}" -f $t.State, $t.Triggers.Count)
# Kick it once now to confirm it runs clean under the scheduler.
Start-ScheduledTask -TaskName $taskName
W "Started task once to validate."
W "=== done ==="
