@echo off
REM Double-click to FORCE an immediate Syncthing sync everywhere reachable, right now.
REM Rescans the laptop's folder + taps RESCAN ALL on any USB/ADB-connected Android device.
REM (Syncthing already auto-syncs in ~1-2s on the LAN; this is the manual "do it now" button.)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\sync-now.ps1" %*
echo.
pause
