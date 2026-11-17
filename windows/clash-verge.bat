@echo off
rem Double-click: install the latest Clash Verge Rev if it is not installed yet, then open it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0clash-verge.ps1" %*
echo.
pause
