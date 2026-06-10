<#
.SYNOPSIS
  Connect to the Android devices over the network (Tailscale) via adb — no USB needed —
  then optionally run the sync health check. Solves "I have to plug in USB every time."

.DESCRIPTION
  Each Android device, once it has had `adb tcpip 5555` run on it ONCE over USB, listens for
  adb on port 5555 across its Tailscale IP. This script just reconnects to those IPs. After a
  device REBOOT, tcpip mode resets — plug it into USB once and run `-Enable` to turn it back on.

.PARAMETER Doctor   After connecting, run scripts/sync-reset.ps1 -Action doctor.
.PARAMETER Enable   Run this with a device on USB to (re)enable wireless adb on it, then connect.

.EXAMPLE
  pwsh scripts/adb-net.ps1            # connect to all known devices over Tailscale
  pwsh scripts/adb-net.ps1 -Doctor   # connect, then full cross-device health report
  pwsh scripts/adb-net.ps1 -Enable   # device on USB -> enable wireless adb on it
#>
[CmdletBinding()]
param([switch]$Doctor, [switch]$Enable)

# Known Android devices (Tailscale IP). Add new devices here — one line each.
$Devices = @(
	@{ name = 'phone (vevins-s25)';  ip = '100.96.229.92' }
	@{ name = 'tablet (vevins-tab-a9)'; ip = '100.93.19.49' }
)
$Port = 5555

if ($Enable) {
	# A device must be on USB for this. Enables tcpip mode so it's reachable over Tailscale.
	$usb = (& adb devices) | Select-String '\tdevice$' | ForEach-Object { ($_ -split '\t')[0] } |
		Where-Object { $_ -notmatch ':\d+$' }   # USB serials only, not ip:port
	if (-not $usb) { Write-Host "No USB device found. Plug one in first." -ForegroundColor Yellow; return }
	foreach ($s in $usb) {
		& adb -s $s tcpip $Port 2>&1 | Out-Null
		Start-Sleep -Seconds 2
		$ip = (& adb -s $s shell "ip -4 addr" 2>$null | Select-String 'inet 100\.' | ForEach-Object { ($_ -replace '.*inet (100\.\d+\.\d+\.\d+).*','$1') } | Select-Object -First 1)
		Write-Host "Enabled wireless adb on USB device $s  (Tailscale IP: $ip)" -ForegroundColor Green
		if ($ip) { & adb connect "${ip}:$Port" 2>&1 | Select-Object -Last 1 }
	}
	return
}

Write-Host "Connecting to Android devices over Tailscale..." -ForegroundColor Cyan
foreach ($d in $Devices) {
	$r = (& adb connect "$($d.ip):$Port" 2>&1 | Select-Object -Last 1)
	$ok = $r -match 'connected'
	$color = if ($ok) { 'Green' } else { 'Yellow' }
	Write-Host ("  {0,-22} {1}  {2}" -f $d.name, "$($d.ip):$Port", $r) -ForegroundColor $color
	if (-not $ok) {
		Write-Host "    -> if this device was rebooted, plug it into USB once and run:  scripts/adb-net.ps1 -Enable" -ForegroundColor DarkGray
	}
}
Write-Host "`nadb devices:" -ForegroundColor Cyan
adb devices | Select-Object -Skip 1 | Where-Object { $_ }

if ($Doctor) {
	$root = Split-Path $PSScriptRoot -Parent
	& powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sync-reset.ps1') -Action doctor
}
