# Registers ObsidianCouchBackup: snapshots the CouchDB volume at logon + daily, keeps newest 14.
$ErrorActionPreference = "Stop"
$out = "C:\obsidian-remember-cursor-position\scripts\_install_backup_task.out.txt"
function W($m){ Add-Content -Path $out -Value $m; Write-Host $m }
Set-Content -Path $out -Value "=== install backup task @ $(Get-Date -Format o) ==="

$script = "C:\obsidian-remember-cursor-position\scripts\sync-couch-backup.ps1"
$pwsh = (Get-Command pwsh).Source
$taskName = "ObsidianCouchBackup"
$me = "$env:USERDOMAIN\$env:USERNAME"

$action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
# Daily at 02:00 + at logon (so every restart leaves a fresh snapshot).
$daily = New-ScheduledTaskTrigger -Daily -At 2:00am
$logon = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $daily, $logon -Principal $principal -Settings $settings -Description "Snapshot the CouchDB (WSL Docker) volume for Obsidian LiveSync. See SYNC-RUNBOOK.md." -Force | Out-Null
W "Registered '$taskName' for $me (daily 02:00 + logon, keep 14)."
$t = Get-ScheduledTask -TaskName $taskName
W ("State={0} Triggers={1}" -f $t.State, $t.Triggers.Count)
W "=== done ==="
