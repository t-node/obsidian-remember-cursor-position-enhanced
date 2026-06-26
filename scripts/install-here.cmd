@echo off
REM ============================================================================
REM  RCP-E one-time bootstrap. Double-click this ON A DEVICE (e.g. the office
REM  laptop) to install the latest plugin build that Syncthing delivered into
REM  this plugin-dist\ folder. After running it ONCE, that device self-updates
REM  on every future deploy and you never need this again.
REM
REM  Self-locating: it sits in <vault>\plugin-dist\, so the vault is one level up.
REM ============================================================================
setlocal
set "DIST=%~dp0"
set "PLUGIN=%DIST%..\.obsidian\plugins\remember-cursor-position-enhanced"

if not exist "%DIST%main.js" (
  echo ERROR: main.js not found next to this script ^(plugin-dist not synced yet?^).
  echo Open Obsidian once so Syncthing finishes, then run this again.
  pause & exit /b 1
)
if not exist "%PLUGIN%" (
  echo ERROR: plugin folder not found at:
  echo   %PLUGIN%
  echo Is the Obsidian vault really one level up from this folder? If not, copy
  echo main.js + manifest.json into your plugin folder manually.
  pause & exit /b 1
)

copy /Y "%DIST%main.js" "%PLUGIN%\main.js" >nul
copy /Y "%DIST%manifest.json" "%PLUGIN%\manifest.json" >nul
if errorlevel 1 ( echo Copy failed. & pause & exit /b 1 )

echo.
echo  Installed the latest RCP-E build into:
echo    %PLUGIN%
echo.
echo  Now RELOAD Obsidian on this device (Ctrl+R) to run it.
echo  After this one time, future builds install themselves automatically.
echo.
pause
