@echo off
REM Double-click this to FORCE every reachable device to match THIS laptop's vault now.
REM (Soft force-replicate: master pushes, phone/tablet are restarted to pull, then it verifies.)
REM For the rare hard rebuild, run:  pwsh scripts\force-sync.ps1 -Hard   (prints the procedure)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\force-sync.ps1" %*
echo.
pause
