@echo off
rem Double-click after reboot: create (or reopen) a signed-out Chrome profile named "claude" and open Chrome with it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0chrome-profile.ps1" %*
echo.
pause
