<#
.SYNOPSIS
  PER-NOTE cursor-sync view. For every note (you have hundreds), shows the reading position each device
  recorded and the position you'll LAND at -- and confirms all devices resolve to the SAME spot.

.DESCRIPTION
  Each device records its scroll/cursor for every note inside cursor-state/<deviceId>.json. LiveSync syncs
  those files, so when they are byte-identical across devices (this script checks that via md5), EVERY
  note's position is identical on every device -- there is no way for one note to differ while the file
  matches. This makes that visible per note, and lets you look up a single note by name.

  Output:
    1. CROSS-DEVICE FILE CHECK -- are the cursor-state files identical on every reachable device? This is
       the hard guarantee: identical files => every note resolves to the same position everywhere.
    2. PER-NOTE RESOLUTION -- for each note, the winning position (latest write) = where you land, plus a
       flag for notes where devices recorded *different* spots (RCP-E lands you at the most recent).

.PARAMETER Note   Only notes whose path contains this text (e.g.  -Note "Udaan Batch 11/8").
.PARAMETER All    List every note (long).
.PARAMETER Diverged  Only list notes where devices disagree on the position right now.

.EXAMPLE
  pwsh scripts\sync-notes.ps1                       # summary + any divergences
  pwsh scripts\sync-notes.ps1 -Note "Udaan 11/8"    # look up one note across devices
  pwsh scripts\sync-notes.ps1 -All                  # every note's resolved position
#>
[CmdletBinding()]
param(
	[string]$Note,
	[switch]$All,
	[switch]$Diverged,
	[string]$VaultDir,
	[int]$ScrollEpsilon = 2
)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_sync-config.ps1"
$haveAdb = $null -ne (Get-Command adb -ErrorAction SilentlyContinue)
$csDir = Join-Path $VaultDir 'cursor-state'

Write-Host "===== PER-NOTE CURSOR SYNC  $(Get-Date -Format 'HH:mm:ss') =====" -ForegroundColor Cyan
if (-not (Test-Path $csDir)) { Write-Host "No cursor-state folder at $csDir" -ForegroundColor Red; exit 1 }

# ---------- 1. CROSS-DEVICE FILE CHECK (the guarantee) ----------
Write-Host "`n[1] CROSS-DEVICE FILE CHECK (identical files => every note in sync everywhere)" -ForegroundColor Cyan
$fileHashes = @{}
Get-ChildItem "$csDir\*.json" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.diag*' } | ForEach-Object {
	if (-not $fileHashes.ContainsKey($_.Name)) { $fileHashes[$_.Name]=@{} }
	$fileHashes[$_.Name]['master'] = (Get-FileHash $_.FullName -Algorithm MD5).Hash.ToLower()
}
if ($haveAdb) {
	foreach ($d in $SyncConfig.Devices) {
		$serial = "$($d.ip):5555"; $null = & adb connect $serial 2>$null
		$names = (& adb -s $serial shell "ls $($d.vault)/cursor-state/*.json 2>/dev/null" 2>$null) | ForEach-Object { ($_ -split '/')[-1].Trim() } | Where-Object { $_ -and $_ -notlike '.diag*' }
		foreach ($nm in $names) {
			$md5 = (& adb -s $serial shell "md5sum $($d.vault)/cursor-state/$nm 2>/dev/null" 2>$null)
			if ($md5) { if (-not $fileHashes.ContainsKey($nm)){$fileHashes[$nm]=@{}}; $fileHashes[$nm][$d.name]=(($md5 -split '\s+')[0]).Trim().ToLower() }
		}
	}
}
$allIdentical = $true
foreach ($f in ($fileHashes.Keys | Sort-Object)) {
	$h = $fileHashes[$f]; $distinct = @($h.Values | Sort-Object -Unique)
	$ok = $distinct.Count -le 1
	if (-not $ok) { $allIdentical = $false }
	Write-Host ("    [{0}] {1}  ({2} device(s))" -f $(if($ok){'OK  '}else{'DIFF'}),$f,$h.Count) -ForegroundColor $(if($ok){'Gray'}else{'Yellow'})
}
if ($allIdentical) { Write-Host "    => Cursor files are IDENTICAL on every reachable device, so EVERY note (all of them) resolves to the same position on every device." -ForegroundColor Green }
else { Write-Host "    => Some cursor files DIFFER right now (a device is mid-sync or backgrounded). The per-note positions below are from the master; wake the lagging device + re-check." -ForegroundColor Yellow }

# ---------- 2. PER-NOTE RESOLUTION ----------
# Build: noteHash -> { filePath, candidates = [{device,scroll,line,rev,lm}] } from ALL device files on master
$byNote = @{}
Get-ChildItem "$csDir\*.json" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.diag*' } | ForEach-Object {
	try { $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
	$dev = $j.deviceId; if (-not $dev) { $dev = $_.BaseName }
	if (-not $j.notes) { return }
	foreach ($p in $j.notes.PSObject.Properties) {
		$n = $p.Value
		$key = if ($n.filePath) { $n.filePath } else { $p.Name }
		if (-not $byNote.ContainsKey($key)) { $byNote[$key] = New-Object System.Collections.Generic.List[object] }
		$line = if ($n.cursor -and $n.cursor.from) { $n.cursor.from.line } else { $null }
		$byNote[$key].Add([pscustomobject]@{ device=$dev; scroll=[double]$n.scroll; line=$line; rev=$n.revision; lm=[int64]$n.lastModified })
	}
}

function Resolve-Note($cands) { $cands | Sort-Object lm -Descending | Select-Object -First 1 }   # latest write wins (RCP-E)
function Is-Diverged($cands) {
	$s = @($cands.scroll); ($s | Measure-Object -Maximum).Maximum - ($s | Measure-Object -Minimum).Minimum -gt $ScrollEpsilon
}

$keys = $byNote.Keys
if ($Note) { $keys = $keys | Where-Object { $_ -like "*$Note*" } }
$keys = @($keys | Sort-Object)

Write-Host "`n[2] PER-NOTE RESOLUTION ($($byNote.Count) notes tracked total$(if($Note){"; $($keys.Count) match '$Note'"}))" -ForegroundColor Cyan
$divCount = 0
$show = $All -or $Note -or $Diverged
foreach ($k in $keys) {
	$cands = $byNote[$k]
	$win = Resolve-Note $cands
	$div = Is-Diverged $cands
	if ($div) { $divCount++ }
	if ($Diverged -and -not $div) { continue }
	if ($show) {
		$tag = if ($div) { 'DIVERGED' } else { 'agree' }
		Write-Host ("  [{0}] {1}" -f $tag,$k) -ForegroundColor $(if($div){'Yellow'}else{'Gray'})
		Write-Host ("      -> most-recent write: scroll {0} line {1}  ({2}, rev {3})  [RCP-E resolves by revision+timestamp; identical files => same result on every device]" -f ([math]::Round($win.scroll,1)),$win.line,$win.device,$win.rev) -ForegroundColor $(if($div){'Yellow'}else{'DarkGray'})
		if ($div -or $All -or $Note) { foreach ($c in ($cands | Sort-Object lm -Descending)) { Write-Host ("         {0,-10} scroll {1,-9} line {2,-5} rev {3}" -f $c.device,([math]::Round($c.scroll,1)),$c.line,$c.rev) } }
	}
}
if (-not $show) {
	Write-Host "  (Use -All to list every note, -Note '<text>' to look one up, -Diverged for only the disagreements.)" -ForegroundColor DarkGray
}
Write-Host "`n  $divCount of $($byNote.Count) notes have devices recording DIFFERENT spots (normal: RCP-E lands you at the most recent)." -ForegroundColor $(if($divCount){'Yellow'}else{'Green'})
if ($allIdentical) { Write-Host "  Because the files are identical everywhere, whatever each note resolves to above is what EVERY device shows." -ForegroundColor Green }
