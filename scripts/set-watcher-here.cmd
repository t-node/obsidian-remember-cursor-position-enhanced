@echo off
REM Double-click ON A DEVICE (e.g. the office laptop) to make Syncthing send/confirm fast.
REM Sets the 'Vault' folder's Watcher Delay to 0.1s using this machine's own Syncthing API key.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0set-watcher-here.ps1" -DelayS 0.1
echo.
pause
