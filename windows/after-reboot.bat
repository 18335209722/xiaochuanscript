@echo off
rem Double-click after reboot: open Chrome with a signed-out profile named "claude", then install and open Clash Verge Rev if it is missing.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0after-reboot.ps1" %*
echo.
pause
