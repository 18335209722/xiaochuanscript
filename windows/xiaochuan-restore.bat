@echo off
rem Double-click to open the restore menu. Arguments are passed through to the script.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0xiaochuan-restore.ps1" %*
if errorlevel 1 pause
