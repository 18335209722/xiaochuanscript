@echo off
rem Double-click to open the menu. Arguments are passed through to the script.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0xiaochuan-env.ps1" %*
if errorlevel 1 pause
