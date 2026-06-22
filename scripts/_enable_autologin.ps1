# Enable Windows auto-login for the no-password Admin account so WSL+CouchDB start at boot
# (boot -> auto sign-in -> ObsidianCouchBridge logon task fires). Reversible: set AutoAdminLogon=0.
$ErrorActionPreference = "Stop"
$out = "C:\obsidian-remember-cursor-position\scripts\_enable_autologin.out.txt"
function W($m){ Add-Content -Path $out -Value $m; Write-Host $m }
Set-Content -Path $out -Value "=== enable autologin @ $(Get-Date -Format o) ==="

$k = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$user = $env:USERNAME
$domain = $env:COMPUTERNAME   # local account -> domain is the machine name

Set-ItemProperty -Path $k -Name "AutoAdminLogon" -Value "1" -Type String
Set-ItemProperty -Path $k -Name "DefaultUserName" -Value $user -Type String
Set-ItemProperty -Path $k -Name "DefaultDomainName" -Value $domain -Type String
Set-ItemProperty -Path $k -Name "DefaultPassword" -Value "" -Type String
# Remove any one-shot logon counter so it persists across every boot.
Remove-ItemProperty -Path $k -Name "AutoLogonCount" -ErrorAction SilentlyContinue
# Some builds hide the netplwiz checkbox; the registry method still applies. Relax the passwordless gate.
$pl = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"
if (Test-Path $pl) {
  try { Set-ItemProperty -Path $pl -Name "DevicePasswordLessBuildVersion" -Value 0 -Type DWord; W "set DevicePasswordLessBuildVersion=0" } catch { W "could not set passwordless gate: $_" }
}

$now = Get-ItemProperty $k
W ("AutoAdminLogon={0} DefaultUserName={1} DefaultDomainName={2}" -f $now.AutoAdminLogon, $now.DefaultUserName, $now.DefaultDomainName)
W "=== done (takes effect next boot) ==="
