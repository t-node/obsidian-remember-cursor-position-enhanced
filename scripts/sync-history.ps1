<#
.SYNOPSIS
  Durable, append-only health logger for the 4-device Obsidian LiveSync cursor-sync setup.
  Run it on a schedule (every 30 min) to build a long history; later run -Analyze to find
  intermittent / race-condition issues (Tailscale outages, the tablet's sync-trigger flags
  resetting to false, CouchDB stalls/bloat, milestone locks, clock skew) across weeks/months.

.DESCRIPTION
  Each SNAPSHOT appends ONE compact JSON line to debug-reports\history\sync-history.jsonl and,
  whenever something changed vs the previous snapshot, a human-readable line to events.log.

  Signals captured every run (rock-solid, from the master, no device needed):
    - CouchDB: reachable, update_seq, doc_count, file/active bytes, compact_running, locked, #accepted_nodes
    - Tailscale: per-peer online flag (+ lastSeen when a peer is OFFLINE)
  Best-effort per Android device (only when wireless adb ip:5555 is reachable):
    - the 5 sync-trigger flags (liveSync/syncOnSave/syncOnStart/periodicReplication/syncOnFileOpen)
      + isConfigured  -> THIS is what catches the recurring "tablet triggers silently reset to false"
    - WiFi (ssid/supplicant/rssi/ip), default-network present, clock skew vs laptop (seconds)

  History lives under debug-reports\ which is gitignored -> stays LOCAL & durable, never committed.

.PARAMETER Analyze    Read the whole history and print + save a retrospective report.
.PARAMETER Install    Register a Windows Scheduled Task to snapshot every -IntervalMinutes.
.PARAMETER Uninstall  Remove that scheduled task.
.PARAMETER IntervalMinutes  Snapshot cadence for -Install (default 30).
.PARAMETER SinceDays  Limit -Analyze to the last N days (default: all history).

.EXAMPLE
  pwsh scripts\sync-history.ps1                 # take one snapshot now (what the task runs)
  pwsh scripts\sync-history.ps1 -Install        # schedule it every 30 min
  pwsh scripts\sync-history.ps1 -Analyze        # retrospective report over all history
  pwsh scripts\sync-history.ps1 -Analyze -SinceDays 21
#>
[CmdletBinding()]
param(
    [switch]$Analyze,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$PullHealth,
    [int]$IntervalMinutes = 30,
    [int]$SinceDays = 0,
    [string]$CouchUrl,[string]$CouchUser,[string]$CouchPass,[string]$DbName,[string]$VaultDir
)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_sync-config.ps1"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$HistDir  = Join-Path $RepoRoot 'debug-reports\history'
$Jsonl    = Join-Path $HistDir 'sync-history.jsonl'
$Events   = Join-Path $HistDir 'events.log'
New-Item -ItemType Directory -Force -Path $HistDir | Out-Null

function Resolve-Adb {
    $c = Get-Command adb -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
    if (Test-Path $p) { return $p }
    return $null
}

# ---------- shared: read a boolean/number/string field out of a JSON-ish blob by key ----------
function Get-JsonField($text,$key) {
    $m = [regex]::Match($text, '"' + [regex]::Escape($key) + '"\s*:\s*("(?<s>[^"]*)"|(?<v>true|false|-?\d+(\.\d+)?))')
    if (-not $m.Success) { return $null }
    if ($m.Groups['s'].Success) { return $m.Groups['s'].Value }
    $v = $m.Groups['v'].Value
    if ($v -eq 'true') { return $true }
    if ($v -eq 'false') { return $false }
    return [double]$v
}

# ============================================================ SNAPSHOT ============================================================
function Invoke-Snapshot {
    $nowUtc = [DateTimeOffset]::UtcNow
    $snap = [ordered]@{
        ts     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        tsUtc  = $nowUtc.ToUnixTimeSeconds()
        host   = $env:COMPUTERNAME
        couch  = $null
        tailscale = @{}
        devices   = @{}
        notes  = @()
    }

    # ---- CouchDB ----
    $auth = "${CouchUser}:${CouchPass}"
    $couch = [ordered]@{ reachable = $false }
    try {
        $raw = curl.exe -s -m 12 -u $auth "$CouchUrl/$DbName" 2>$null
        if ($raw -and $raw -match '"db_name"') {
            $couch.reachable    = $true
            $couch.update_seq   = [int]([regex]::Match($raw,'"update_seq":"?(\d+)').Groups[1].Value)
            $couch.doc_count    = [int](Get-JsonField $raw 'doc_count')
            $couch.file_bytes   = [long](Get-JsonField $raw 'file')
            $couch.active_bytes = [long](Get-JsonField $raw 'active')
            $cr = Get-JsonField $raw 'compact_running'; $couch.compact_running = [bool]$cr
        }
    } catch { $snap.notes += "couch-db error: $($_.Exception.Message)" }
    try {
        $ms = curl.exe -s -m 12 -u $auth "$CouchUrl/$DbName/_local/obsydian_livesync_milestone" 2>$null
        if ($ms -and $ms -match '"locked"') {
            $lk = Get-JsonField $ms 'locked'; $couch.locked = [bool]$lk
            $couch.accepted_nodes = ([regex]::Matches((([regex]::Match($ms,'"accepted_nodes":\[(?<a>[^\]]*)\]')).Groups['a'].Value),'"[^"]+"')).Count
        }
    } catch {}
    # ANTI-BLOAT GUARD: reclaim disk overhead automatically before it grows
    if ($couch.reachable -and $couch.file_bytes -and $couch.active_bytes -and -not $couch.compact_running) {
        $reclaimable = [long]$couch.file_bytes - [long]$couch.active_bytes
        if ($reclaimable -gt 50MB) {
            try {
                curl.exe -s -m 10 -X POST -u $auth "$CouchUrl/$DbName/_compact" -H "Content-Type: application/json" 2>$null | Out-Null
                $snap.notes += ("auto-compact triggered ({0} MB reclaimable)" -f [math]::Round($reclaimable/1MB))
            } catch {}
        }
    }
    $snap.couch = $couch

    # ---- Tailscale (per peer + self) ----
    try {
        $tj = (tailscale status --json 2>$null | ConvertFrom-Json)
        if ($tj) {
            $all = @()
            if ($tj.Self) { $all += $tj.Self }
            if ($tj.Peer) { $all += ($tj.Peer.PSObject.Properties | ForEach-Object { $_.Value }) }
            foreach ($p in $all) {
                $name = $p.HostName
                if (-not $name) { continue }
                $e = [ordered]@{ online = [bool]$p.Online }
                # Tailscale only fills LastSeen meaningfully when a peer is OFFLINE
                if (-not $p.Online -and $p.LastSeen) {
                    try { $ls = [DateTimeOffset]::Parse($p.LastSeen); if ($ls.Year -gt 2000) { $e.lastSeen = $ls.ToString('yyyy-MM-ddTHH:mm:ssK') } } catch {}
                }
                $snap.tailscale[$name] = $e
            }
        }
    } catch { $snap.notes += "tailscale error: $($_.Exception.Message)" }

    # ---- Per-device adb detail (best effort; only if wireless adb reachable) ----
    $adb = Resolve-Adb
    if ($adb) {
        foreach ($d in $Devices) {
            $serial = "$($d.ip):5555"
            $dev = [ordered]@{ adbReachable = $false }
            try {
                $c = (& $adb connect $serial 2>&1 | Select-Object -Last 1)
                if ("$c" -match 'connected') {
                    $dev.adbReachable = $true
                    # sync-trigger flags from livesync data.json
                    $cfg = "$($d.vault)/.obsidian/plugins/obsidian-livesync/data.json"
                    $txt = (& $adb -s $serial shell "cat '$cfg'" 2>$null) -join "`n"
                    if ($txt) {
                        $dev.flags = [ordered]@{}
                        foreach ($k in 'liveSync','syncOnSave','syncOnStart','periodicReplication','syncOnFileOpen','isConfigured') {
                            $val = Get-JsonField $txt $k
                            if ($null -ne $val) { $dev.flags[$k] = [bool]$val }
                        }
                    } else { $snap.notes += "$($d.name): could not read livesync config" }
                    # wifi
                    $wifi = (& $adb -s $serial shell "dumpsys wifi 2>/dev/null | grep -m1 'mWifiInfo'" 2>$null) -join ' '
                    if ($wifi) {
                        $w = [ordered]@{}
                        $w.ssid       = ([regex]::Match($wifi,'SSID:\s*"?([^",]+)"?')).Groups[1].Value.Trim()
                        $w.supplicant = ([regex]::Match($wifi,'Supplicant state:\s*([A-Z_]+)')).Groups[1].Value
                        $rssi = ([regex]::Match($wifi,'RSSI:\s*(-?\d+)')).Groups[1].Value; if ($rssi) { $w.rssi = [int]$rssi }
                        $w.ip = ([regex]::Match($wifi,'IP:\s*/?([\d.]+)')).Groups[1].Value
                        $dev.wifi = $w
                    }
                    # default network present?
                    $net = (& $adb -s $serial shell "dumpsys connectivity 2>/dev/null | grep -m1 'Active default network'" 2>$null) -join ' '
                    $dev.defaultNet = [bool]($net -match 'Active default network:\s*\d')
                    # clock skew (Android `date +%s` is real UTC epoch)
                    $devEpoch = (& $adb -s $serial shell "date +%s" 2>$null | Select-Object -First 1)
                    if ($devEpoch -match '^\d+$') { $dev.clockSkewSec = [int]$devEpoch - [int]$nowUtc.ToUnixTimeSeconds() }
                }
            } catch { $snap.notes += "$($d.name) adb error: $($_.Exception.Message)" }
            $snap.devices[$d.name] = $dev
        }
        & $adb disconnect 2>$null | Out-Null
    } else { $snap.notes += "adb not found; device-level detail skipped" }

    # ---- append JSONL ----
    $line = ($snap | ConvertTo-Json -Depth 8 -Compress)
    Add-Content -Path $Jsonl -Value $line -Encoding utf8

    # ---- diff vs previous snapshot -> events.log (the human-readable trace) ----
    Write-Transitions $snap
    Write-Host ("[{0}] snapshot saved -> {1}" -f $snap.ts, $Jsonl) -ForegroundColor Green
    return $snap
}

function Read-LastSnapshot {
    if (-not (Test-Path $Jsonl)) { return $null }
    $last = Get-Content $Jsonl -Tail 2 -Encoding utf8 | Where-Object { $_.Trim() } | Select-Object -Last 1
    if (-not $last) { return $null }
    try { return ($last | ConvertFrom-Json) } catch { return $null }
}

function Write-Transitions($cur) {
    $prev = $script:PrevSnap
    if ($null -eq $prev) { return }   # nothing to diff against yet
    $ev = @()
    # couch reachability + lock + bloat
    if ([bool]$prev.couch.reachable -ne [bool]$cur.couch.reachable) {
        $ev += ("CouchDB " + ($(if($cur.couch.reachable){'REACHABLE again'}else{'UNREACHABLE'})))
    }
    if ($cur.couch.reachable -and $prev.couch.reachable -and ([bool]$prev.couch.locked) -ne ([bool]$cur.couch.locked)) {
        $ev += ("CouchDB milestone " + ($(if($cur.couch.locked){'LOCKED'}else{'unlocked'})))
    }
    # tailscale online transitions
    foreach ($name in $cur.tailscale.PSObject.Properties.Name) {
        $now = $cur.tailscale.$name.online
        $was = $prev.tailscale.$name.online
        if ($null -ne $was -and [bool]$was -ne [bool]$now) {
            $ev += ("$name Tailscale " + ($(if($now){'ONLINE'}else{'OFFLINE'})))
        }
    }
    # device flag flips (the key one)
    foreach ($dn in $cur.devices.PSObject.Properties.Name) {
        $cf = $cur.devices.$dn.flags; $pf = $prev.devices.$dn.flags
        if ($null -eq $cf -or $null -eq $pf) { continue }
        foreach ($k in $cf.PSObject.Properties.Name) {
            $nv = $cf.$k; $ov = $pf.$k
            if ($null -ne $ov -and [bool]$ov -ne [bool]$nv) {
                $ev += ("$dn flag $k -> $nv")
            }
        }
        # wifi disconnect
        $cw = $cur.devices.$dn.wifi; $pw = $prev.devices.$dn.wifi
        if ($cw -and $pw -and $cw.supplicant -ne $pw.supplicant) { $ev += ("$dn wifi supplicant $($pw.supplicant) -> $($cw.supplicant)") }
    }
    foreach ($e in $ev) { Add-Content -Path $Events -Value ("{0}  {1}" -f $cur.ts, $e) -Encoding utf8; Write-Host "  CHANGE: $e" -ForegroundColor Yellow }
}

# ============================================================ ANALYZE ============================================================
function Invoke-Analyze {
    if (-not (Test-Path $Jsonl)) { Write-Host "No history yet at $Jsonl -- run a snapshot first (or wait for the scheduled task)." -ForegroundColor Yellow; return }
    $cutoff = if ($SinceDays -gt 0) { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - ($SinceDays*86400) } else { 0 }
    $rows = @()
    foreach ($l in (Get-Content $Jsonl -Encoding utf8)) {
        if (-not $l.Trim()) { continue }
        try { $o = $l | ConvertFrom-Json } catch { continue }
        if ($o.tsUtc -ge $cutoff) { $rows += $o }
    }
    if ($rows.Count -eq 0) { Write-Host "No samples in the selected window." -ForegroundColor Yellow; return }
    $rows = $rows | Sort-Object tsUtc

    $out = New-Object System.Collections.Generic.List[string]
    function W($s){ $out.Add($s); Write-Host $s }
    function Fmt($u){ ([DateTimeOffset]::FromUnixTimeSeconds([int64]$u).ToLocalTime()).ToString('yyyy-MM-dd HH:mm') }
    function Dur($sec){ $t=[TimeSpan]::FromSeconds([math]::Max(0,$sec)); if($t.TotalDays-ge1){'{0:n0}d {1}h'-f[math]::Floor($t.TotalDays),$t.Hours}elseif($t.TotalHours-ge1){'{0}h {1}m'-f[math]::Floor($t.TotalHours),$t.Minutes}else{'{0}m'-f[math]::Floor($t.TotalMinutes)} }

    $verdict = @()
    W ("=" * 78)
    W ("  SYNC HISTORY ANALYSIS   {0} samples   {1}  ->  {2}" -f $rows.Count, (Fmt $rows[0].tsUtc), (Fmt $rows[-1].tsUtc))
    W ("=" * 78)

    # ---- coverage gaps (laptop asleep / task not running) ----
    $gapThresh = ($IntervalMinutes * 60) * 2.5
    $gaps = @()
    for ($i=1; $i -lt $rows.Count; $i++) {
        $d = $rows[$i].tsUtc - $rows[$i-1].tsUtc
        if ($d -gt $gapThresh) { $gaps += @{ from=$rows[$i-1].tsUtc; to=$rows[$i].tsUtc; dur=$d } }
    }
    W ""
    W "## COVERAGE"
    W ("   expected cadence ~{0} min; {1} coverage gap(s) > {2:n0} min (laptop asleep / task off):" -f $IntervalMinutes,$gaps.Count,($gapThresh/60))
    foreach ($g in ($gaps | Select-Object -Last 8)) { W ("     gap {0}  ({1} -> {2})" -f (Dur $g.dur),(Fmt $g.from),(Fmt $g.to)) }

    # ---- CouchDB ----
    $cReach = $rows | Where-Object { $_.couch.reachable }
    W ""
    W "## COUCHDB"
    $downRuns = Get-FalseRuns $rows { param($r) -not $r.couch.reachable }
    if ($downRuns.Count) { $verdict += "CouchDB had $($downRuns.Count) unreachable window(s)"; foreach($r in $downRuns){ W ("   UNREACHABLE {0}  ({1} -> {2})" -f (Dur $r.dur),(Fmt $r.from),(Fmt $r.to)) } }
    else { W "   reachable in every sample." }
    if ($cReach.Count -ge 2) {
        $seqMin=($cReach.couch.update_seq|Measure-Object -Minimum).Minimum; $seqMax=($cReach.couch.update_seq|Measure-Object -Maximum).Maximum
        $aFirst=$cReach[0].couch.active_bytes; $aLast=$cReach[-1].couch.active_bytes; $aMax=($cReach.couch.active_bytes|Measure-Object -Maximum).Maximum
        $dFirst=$cReach[0].couch.doc_count;    $dLast=$cReach[-1].couch.doc_count
        W ("   update_seq {0} -> {1}   (moving = replication happening)" -f $seqMin,$seqMax)
        W ("   doc_count  {0} -> {1}" -f $dFirst,$dLast)
        W ("   active     {0:n1} MB -> {1:n1} MB   (peak {2:n1} MB)" -f ($aFirst/1MB),($aLast/1MB),($aMax/1MB))
        if ($aFirst -gt 0 -and $aLast -gt $aFirst*1.5) { $verdict += ("CouchDB bloat grew {0:n0}% ({1:n0}->{2:n0} MB) -- consider a rebuild" -f ((($aLast-$aFirst)/$aFirst)*100),($aFirst/1MB),($aLast/1MB)) }
        if ($aLast -gt 60MB) { $verdict += ("CouchDB active bloat {0:n0} MB (>60MB threshold) -- deep-clean: pwsh scripts\sync-reset.ps1 -Action wipe (then Overwrite remote)" -f ($aLast/1MB)) }
        # longest frozen-seq window while reachable (possible stall)
        $frozen = Get-FrozenSeq $cReach
        if ($frozen.dur -gt 6*3600) { W ("   longest update_seq FROZEN window: {0}  ({1} -> {2})  <- stall if anyone was editing" -f (Dur $frozen.dur),(Fmt $frozen.from),(Fmt $frozen.to)) }
        $lockRuns = Get-FalseRuns $cReach { param($r) [bool]$r.couch.locked }
        foreach ($r in $lockRuns) { W ("   milestone LOCKED {0}  ({1} -> {2})" -f (Dur $r.dur),(Fmt $r.from),(Fmt $r.to)); $verdict += "CouchDB was milestone-LOCKED (blocks all pushes)" }
    }

    # ---- per device ----
    $devNames = @(); $rows | ForEach-Object { $_.devices.PSObject.Properties.Name | ForEach-Object { if ($devNames -notcontains $_){$devNames+=$_} } }
    $tsNames  = @(); $rows | ForEach-Object { $_.tailscale.PSObject.Properties.Name | ForEach-Object { if ($tsNames -notcontains $_){$tsNames+=$_} } }
    W ""
    W "## TAILSCALE OUTAGES (per peer)"
    foreach ($n in ($tsNames | Sort-Object)) {
        $offRuns = Get-OfflineRuns $rows $n
        if ($offRuns.Count) {
            $total = ($offRuns.dur | Measure-Object -Sum).Sum; $longest=($offRuns.dur|Measure-Object -Maximum).Maximum
            W ("   {0,-16} {1} outage(s), total {2}, longest {3}" -f $n,$offRuns.Count,(Dur $total),(Dur $longest))
            foreach ($r in ($offRuns | Select-Object -Last 5)) { W ("        offline {0}  ({1} -> {2})" -f (Dur $r.dur),(Fmt $r.from),(Fmt $r.to)) }
            $verdict += "$n had $($offRuns.Count) Tailscale outage(s) (longest $(Dur $longest))"
        } else { W ("   {0,-16} no outages" -f $n) }
    }

    W ""
    W "## SYNC-TRIGGER FLAG FLIPS  (the recurring 'tablet triggers reset to false' race)"
    $anyFlip = $false
    foreach ($dn in ($devNames | Sort-Object)) {
        $withFlags = $rows | Where-Object { $_.devices.$dn -and $_.devices.$dn.flags }
        if ($withFlags.Count -lt 2) { W ("   {0,-10} only {1} sample(s) with flag data (wireless adb rarely reachable) -- enable it to track this" -f $dn,$withFlags.Count); continue }
        $keys = 'liveSync','syncOnSave','syncOnStart','periodicReplication','syncOnFileOpen'
        $flips = @()
        for ($i=1; $i -lt $withFlags.Count; $i++) {
            foreach ($k in $keys) {
                $ov = $withFlags[$i-1].devices.$dn.flags.$k; $nv = $withFlags[$i].devices.$dn.flags.$k
                if ($null -ne $ov -and $null -ne $nv -and [bool]$ov -ne [bool]$nv) { $flips += ("{0}  {1}: {2} -> {3}" -f (Fmt $withFlags[$i].tsUtc),$k,$ov,$nv) }
            }
        }
        $lastFlags = $withFlags[-1].devices.$dn.flags
        $allOff = -not ($keys | Where-Object { [bool]$lastFlags.$_ })
        W ("   {0,-10} {1} flag-flip event(s); latest flags: {2}" -f $dn,$flips.Count, (($keys | ForEach-Object { "$_=$([bool]$lastFlags.$_)" }) -join ' '))
        foreach ($f in ($flips | Select-Object -Last 8)) { W ("        $f"); $anyFlip=$true }
        if ($allOff) { $verdict += "$dn currently has ALL sync triggers OFF (won't replicate on its own -- set a sync-mode preset in the LiveSync UI)" }
    }
    if (-not $anyFlip) { W "   (no flips captured -- needs >=2 samples with wireless adb reachable to the device)" }

    # ---- clock skew ----
    W ""
    W "## CLOCK SKEW (device vs laptop, seconds)"
    foreach ($dn in ($devNames | Sort-Object)) {
        $sk = $rows | Where-Object { $null -ne $_.devices.$dn.clockSkewSec } | ForEach-Object { $_.devices.$dn.clockSkewSec }
        if ($sk.Count) { $mx=($sk|ForEach-Object{[math]::Abs($_)}|Measure-Object -Maximum).Maximum; W ("   {0,-10} max |skew| {1}s over {2} sample(s)" -f $dn,$mx,$sk.Count); if($mx -gt 30){$verdict+="$dn clock skew up to ${mx}s (can make the wrong cursor position win)"} }
    }

    # ---- ON-DEVICE HEALTH LOGS (sync-health/, written BY each device — sees what home cannot) ----
    W ""
    W "## ON-DEVICE HEALTH LOGS (sync-health/ — each device's own view, incl. while away from home)"
    $healthDir = Join-Path $VaultDir 'sync-health'
    if (-not (Test-Path $healthDir)) {
        W "   none yet at $healthDir (plugin v2.2.0+ writes these; they arrive when the device syncs, or via -PullHealth)"
    } else {
        $hrows = @()
        Get-ChildItem -Path $healthDir -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue | ForEach-Object {
            foreach ($l in (Get-Content $_.FullName -Encoding utf8)) {
                if (-not $l.Trim()) { continue }
                try { $o = $l | ConvertFrom-Json } catch { continue }
                if (-not $o.tsEpoch) { continue }
                $sec = [int64][math]::Floor([double]$o.tsEpoch / 1000)
                if ($sec -lt $cutoff) { continue }
                $o | Add-Member -NotePropertyName tsUtc -NotePropertyValue $sec -Force
                $hrows += $o
            }
        }
        if ($hrows.Count -eq 0) { W "   no health samples in window." }
        else {
            $byDev = $hrows | Group-Object { if ($_.deviceName) { $_.deviceName } else { $_.deviceId } }
            foreach ($g in ($byDev | Sort-Object Name)) {
                $rs = $g.Group | Sort-Object tsUtc
                W ("   {0}  ({1} samples, {2} -> {3})" -f $g.Name, $rs.Count, (Fmt $rs[0].tsUtc), (Fmt $rs[-1].tsUtc))
                # offline windows as the DEVICE itself saw them
                $offRuns = Get-FalseRuns $rs { param($r) $r.online -eq $false }
                foreach ($r in ($offRuns | Select-Object -Last 6)) { W ("        OFFLINE (self-reported) {0}  ({1} -> {2})" -f (Dur $r.dur),(Fmt $r.from),(Fmt $r.to)); $verdict += "$($g.Name) self-reported offline $(Dur $r.dur) (captured on-device)" }
                # could-not-reach-CouchDB while having a network (server/Tailscale issue, not the device's wifi)
                $probeRuns = Get-FalseRuns $rs { param($r) $r.couchProbe -and ($r.couchProbe.reachable -eq $false) -and ($r.online -eq $true) }
                foreach ($r in ($probeRuns | Select-Object -Last 6)) { W ("        ONLINE but COUCHDB UNREACHABLE {0}  ({1} -> {2})" -f (Dur $r.dur),(Fmt $r.from),(Fmt $r.to)); $verdict += "$($g.Name) had network but could NOT reach CouchDB for $(Dur $r.dur) (server/Tailscale, not device wifi)" }
                # LiveSync trigger flag flips, as recorded ON the device (catches the reset even while away)
                $keys = 'liveSync','syncOnSave','syncOnStart','periodicReplication','syncOnFileOpen'
                $withFlags = $rs | Where-Object { $_.livesync }
                for ($i=1; $i -lt $withFlags.Count; $i++) {
                    foreach ($k in $keys) {
                        $ov = $withFlags[$i-1].livesync.$k; $nv = $withFlags[$i].livesync.$k
                        if ($null -ne $ov -and $null -ne $nv -and [bool]$ov -ne [bool]$nv) {
                            $arrow = if ([bool]$nv) { 'ON (fix)' } else { 'OFF' }
                            W ("        flag {0}: -> {1}  at {2}" -f $k,$arrow,(Fmt $withFlags[$i].tsUtc))
                            # Only a trigger turning OFF is a problem; turning ON is a fix (don't cry wolf).
                            if (-not [bool]$nv) { $verdict += "$($g.Name) sync trigger '$k' was turned OFF at $(Fmt $withFlags[$i].tsUtc) (would stop it syncing)" }
                        }
                    }
                }
                if ($withFlags.Count) {
                    $lf = $withFlags[-1].livesync
                    $allOff = -not ($keys | Where-Object { [bool]$lf.$_ })
                    if ($allOff) { W "        latest flags: ALL triggers OFF (won't replicate on its own)" }
                }
            }
        }
    }

    # ---- verdict ----
    W ""
    W ("=" * 78)
    if ($verdict.Count -eq 0) { W "  VERDICT: GREEN -- no outages, stalls, lock events, or flag flips in this window." }
    else { W "  VERDICT: issues found:"; $verdict | Select-Object -Unique | ForEach-Object { W "    - $_" } }
    W ("=" * 78)

    $rep = Join-Path $HistDir ("ANALYSIS-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [System.IO.File]::WriteAllText($rep, ($out -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ""
    Write-Host "==> Full report saved: $rep" -ForegroundColor Green
}

# return contiguous runs where predicate is TRUE: @{from;to;dur} (using sample timestamps)
function Get-FalseRuns($rows,[scriptblock]$pred) {
    $runs=@(); $start=$null; $prevTs=$null
    foreach ($r in $rows) {
        $hit = & $pred $r
        if ($hit -and $null -eq $start) { $start = $r.tsUtc }
        if (-not $hit -and $null -ne $start) { $runs += @{ from=$start; to=$prevTs; dur=($prevTs-$start) }; $start=$null }
        $prevTs = $r.tsUtc
    }
    if ($null -ne $start) { $runs += @{ from=$start; to=$prevTs; dur=($prevTs-$start) } }
    return $runs
}
# offline runs for one tailscale peer (member-access via $peer handles names with spaces/apostrophes)
function Get-OfflineRuns($rows,$peer) {
    $runs=@(); $start=$null; $prevTs=$null
    foreach ($r in $rows) {
        $p = $r.tailscale.$peer
        $off = ($null -ne $p) -and (-not $p.online)
        if ($off -and $null -eq $start) { $start = $r.tsUtc }
        if (-not $off -and $null -ne $start) { $runs += @{ from=$start; to=$prevTs; dur=($prevTs-$start) }; $start=$null }
        $prevTs = $r.tsUtc
    }
    if ($null -ne $start) { $runs += @{ from=$start; to=$prevTs; dur=($prevTs-$start) } }
    return $runs
}
function Get-FrozenSeq($cReach) {
    $best=@{dur=0;from=0;to=0}; $start=$cReach[0].tsUtc; $val=$cReach[0].couch.update_seq; $prevTs=$cReach[0].tsUtc
    foreach ($r in $cReach) {
        if ($r.couch.update_seq -ne $val) { $d=$prevTs-$start; if($d -gt $best.dur){$best=@{dur=$d;from=$start;to=$prevTs}}; $start=$r.tsUtc; $val=$r.couch.update_seq }
        $prevTs=$r.tsUtc
    }
    $d=$prevTs-$start; if($d -gt $best.dur){$best=@{dur=$d;from=$start;to=$prevTs}}
    return $best
}

# ============================================================ INSTALL / UNINSTALL ============================================================
$TaskName = 'ObsidianSyncHistory'
function Invoke-Install {
    $pwsh = (Get-Process -Id $PID).Path; if (-not $pwsh) { $pwsh = (Get-Command pwsh).Source }
    $script = Join-Path $PSScriptRoot 'sync-history.ps1'
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`"") -WorkingDirectory $RepoRoot
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Snapshot Obsidian LiveSync health every $IntervalMinutes min for retrospective race-condition analysis." -Force | Out-Null
        Write-Host "Registered scheduled task '$TaskName' -> snapshot every $IntervalMinutes min (starts when available, catches up after sleep)." -ForegroundColor Green
        Write-Host "  Runs: $pwsh -File $script" -ForegroundColor Gray
        Write-Host "  History: $Jsonl" -ForegroundColor Gray
    } catch { Write-Host "Failed to register task: $($_.Exception.Message)" -ForegroundColor Red; Write-Host "  (Try running this once from an elevated PowerShell.)" -ForegroundColor Yellow }
}
function Invoke-Uninstall {
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green }
    catch { Write-Host "No task '$TaskName' to remove (or removal failed): $($_.Exception.Message)" -ForegroundColor Yellow }
}

# Pull each reachable device's on-device sync-health logs straight into the master vault's sync-health/.
# Use this when a device was away with BROKEN sync (so its health logs never replicated home) — connect it
# (USB or wireless adb) and run this to bring the logs home, then -Analyze sees them.
function Invoke-PullHealth {
    $adb = Resolve-Adb
    if (-not $adb) { Write-Host "adb not found." -ForegroundColor Red; return }
    $destRoot = Join-Path $VaultDir 'sync-health'
    New-Item -ItemType Directory -Force -Path $destRoot | Out-Null
    $total = 0
    foreach ($d in $Devices) {
        $serial = "$($d.ip):5555"
        if ((& $adb connect $serial 2>&1 | Select-Object -Last 1) -notmatch 'connected') { Write-Host "  $($d.name): not reachable over wireless adb (skip)" -ForegroundColor Yellow; continue }
        $base = "$($d.vault)/sync-health"
        $files = (& $adb -s $serial shell "find '$base' -type f -name '*.jsonl' 2>/dev/null" 2>$null) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $n = 0
        foreach ($f in $files) {
            $rel = $f.Substring($base.Length).TrimStart('/')
            $dest = Join-Path $destRoot ($rel -replace '/','\')
            New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
            & $adb -s $serial pull "$f" "$dest" 2>$null | Out-Null
            if (Test-Path $dest) { $n++ }
        }
        Write-Host ("  {0}: pulled {1} health file(s)" -f $d.name, $n) -ForegroundColor Green
        $total += $n
    }
    & $adb disconnect 2>$null | Out-Null
    Write-Host ("Pulled {0} on-device health file(s) -> {1}" -f $total, $destRoot) -ForegroundColor Green
    Write-Host "Now run:  pwsh scripts\sync-history.ps1 -Analyze" -ForegroundColor Gray
}

# ============================================================ DISPATCH ============================================================
if ($Install)    { Invoke-Install; return }
if ($Uninstall)  { Invoke-Uninstall; return }
if ($PullHealth) { Invoke-PullHealth; return }
if ($Analyze)    { Invoke-Analyze; return }
$script:PrevSnap = Read-LastSnapshot   # capture BEFORE writing the new line, for transition diff
Invoke-Snapshot | Out-Null
