<#
.SYNOPSIS
  RUN THIS ONE. The single entry point: it runs the full assurance check (wake -> connections ->
  same node -> live replication -> byte-for-byte content parity) AND appends every piece of raw
  diagnostic data, all into ONE file you paste into Copilot / Code Cloud.

.DESCRIPTION
  Step A: runs sync-assure.ps1 (which itself runs sync-checkup + sync-verify) and shows the green-light
          verdict: PERFECT SYNC, or NOT YET with the exact failing device/phase.
  Step B: appends a RAW APPENDIX so an AI (or you) can dig deeper than the summary:
            - CouchDB info, _all_dbs, and the full milestone doc (every node + last_connected).
            - Each reachable device's full LiveSync sync-mode config + db name (proves same node).
            - Full RCP-E log tails and every device's .diag sync-decision file.
  Everything lands in debug-reports\sync-all-<time>.txt. That one file is the whole picture.

.PARAMETER NoWake   Don't foreground the phones/tablets first (test them as-is).
.PARAMETER Warmup   Seconds to let woken devices replicate before testing (default 25).

.EXAMPLE
  pwsh scripts\sync-all.ps1
  # open the printed file, paste it into Copilot, ask "is everything in sync; if not, what's the fix?"
#>
[CmdletBinding()]
param(
	[switch]$NoWake,
	[int]$Warmup = 25,
	[string]$CouchUrl = 'http://127.0.0.1:5984',
	[string]$CouchUser,
	[string]$CouchPass,
	[string]$DbName,
	[string]$VaultDir
)
. "$PSScriptRoot\_sync-config.ps1"
$ErrorActionPreference = 'Continue'
$Auth = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${CouchUser}:${CouchPass}")))" }
$enc = New-Object System.Text.UTF8Encoding($false)
$Android = $SyncConfig.Devices
$haveAdb = $null -ne (Get-Command adb -ErrorAction SilentlyContinue)
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'debug-reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$report = Join-Path $reportDir "sync-all-$ts.txt"
$lines = New-Object System.Collections.Generic.List[string]
function W($s){ $lines.Add(($s -replace '\e\[[0-9;]*m','')) }

# ============ STEP A: full assurance (shown live + captured) ============
$assureArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'sync-assure.ps1'),'-Warmup',$Warmup)
if ($NoWake) { $assureArgs += '-NoWake' }
$assureOut = & powershell @assureArgs 2>&1 | ForEach-Object { $s="$_"; Write-Host $s; $s }
$assureOut | ForEach-Object { $lines.Add($_) }
$verdictPass = [bool](@($assureOut | Where-Object { $_ -match 'PERFECT SYNC  -- ALL DEVICES GREEN' }).Count)

# ============ STEP B: RAW APPENDIX ============
W ""
W "##############################################################################"
W "# RAW APPENDIX (full diagnostic data for deeper analysis)"
W "##############################################################################"

W ""
W "## A. COUCHDB"
try { $info = Invoke-RestMethod "$CouchUrl/$DbName" -Headers $Auth -TimeoutSec 8
	W ("  db=$DbName docs=$($info.doc_count) deleted=$($info.doc_del_count) update_seq=$(($info.update_seq -split '-')[0]) sizes.active=$([math]::Round($info.sizes.active/1MB,2))MB file=$([math]::Round($info.sizes.file/1MB,2))MB") } catch { W "  CouchDB info error: $($_.Exception.Message)" }
try { $alldbs = Invoke-RestMethod "$CouchUrl/_all_dbs" -Headers $Auth -TimeoutSec 8; W ("  _all_dbs: " + ($alldbs -join ', ')) } catch { W "  _all_dbs error: $($_.Exception.Message)" }

W ""
W "## B. MILESTONE (every node CouchDB has seen + last_connected)"
try {
	$now=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
	$mile = Invoke-RestMethod "$CouchUrl/$DbName/_local%2Fobsydian_livesync_milestone" -Headers $Auth -TimeoutSec 8
	W "  locked=$($mile.locked)  accepted_nodes=$(@($mile.accepted_nodes) -join ',')"
	$mile.node_info.PSObject.Properties | Sort-Object { $_.Value.last_connected } -Descending | ForEach-Object {
		$sec=[math]::Round(($now-$_.Value.last_connected)/1000)
		W ("    node={0,-12} vault='{1}' last_connected={2} ({3}s ago)" -f $_.Name,$_.Value.vault_name,$_.Value.last_connected,$sec)
	}
} catch { W "  milestone error: $($_.Exception.Message)" }

W ""
W "## C. PER-DEVICE LIVESYNC CONFIG (same node? same db? reliable mode?)"
function DumpCfg($label,$c){
	W ("  [$label] dbName='$($c.couchDB_DBNAME)' liveSync=$($c.liveSync) periodic=$($c.periodicReplication) int=$($c.periodicReplicationInterval) onSave=$($c.syncOnSave) onOpen=$($c.syncOnFileOpen) onStart=$($c.syncOnStart) history=$($c.useHistory) ignore='$($c.syncIgnoreRegEx)'")
}
$lapCfg = "$VaultDir\.obsidian\plugins\obsidian-livesync\data.json"
if (Test-Path $lapCfg) { DumpCfg 'master' (Get-Content $lapCfg -Raw | ConvertFrom-Json) }
if ($haveAdb) {
	foreach ($d in $Android) {
		$serial="$($d.ip):5555"; $null = & adb connect $serial 2>$null
		$raw=(& adb -s $serial shell "cat '$($d.vault)/.obsidian/plugins/obsidian-livesync/data.json'" 2>$null) -join "`n"
		if ($raw) { DumpCfg $d.name ($raw | ConvertFrom-Json) } else { W "  [$($d.name)] OFFLINE / config unreadable" }
	}
}

W ""
W "## D. RCP-E PLUGIN CONFIG (master)"
$rcp = "$VaultDir\.obsidian\plugins\remember-cursor-position-enhanced\data.json"
if (Test-Path $rcp) { $r = Get-Content $rcp -Raw | ConvertFrom-Json
	W ("  logToFile=$($r.logToFile) debugLogging=$($r.debugLogging) saveDebounceMs=$($r.saveDebounceMs) useHistory=$($r.useHistory)") } else { W "  (RCP-E config not found at master)" }

W ""
W "## E. LOGS + SYNC DECISIONS"
$mlog = Get-ChildItem "$VaultDir\rcp-enhanced-logs\*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($mlog) { W "  -- master RCP-E $($mlog.Name) (last 20) --"; Get-Content $mlog.FullName -Tail 20 -Encoding UTF8 | ForEach-Object { W "     $_" } } else { W "  (no master RCP-E log -- logging off = correct for normal running)" }
if ($haveAdb) {
	foreach ($d in $Android) {
		$serial="$($d.ip):5555"
		$diag=(& adb -s $serial shell "cat $($d.vault)/cursor-state/.diag-*.json 2>/dev/null" 2>$null) -join "`n"
		if ($diag) { try { $ev=($diag | ConvertFrom-Json).events | Select-Object -Last 6
			W "  -- $($d.name) recent sync decisions --"; $ev | ForEach-Object { W "     $($_.ts) $($_.event) trigger=$($_.trigger) winner=$($_.winnerDeviceId)" } } catch {} }
	}
}

W ""
W "## FOR COPILOT / CODE CLOUD"
W "  This is the complete diagnostic bundle for an Obsidian cursor-sync setup (Self-hosted LiveSync ->"
W "  CouchDB in WSL on the master, remote devices over Tailscale; master uses 127.0.0.1). The top of the"
W "  file has the green-light verdict + a SYSTEM section explaining the setup. If the verdict is NOT YET,"
W "  tell me which device/layer is failing, in which direction, and the exact fix. Use sections A-E to verify."

[System.IO.File]::WriteAllText($report, ($lines -join "`r`n"), $enc)
Write-Host ""
if ($verdictPass) { Write-Host "==> ALL GREEN. Full bundle saved: $report" -ForegroundColor Green }
else { Write-Host "==> NOT YET in perfect sync (see verdict above). Full bundle saved: $report" -ForegroundColor Yellow }
Write-Host "    Paste that one file into Copilot / Code Cloud for analysis." -ForegroundColor Green
