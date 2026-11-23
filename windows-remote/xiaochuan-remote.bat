@echo off
rem Double-click to set this PC up for remote command-line use: OpenSSH server, PowerShell as the SSH shell, Claude Code CLI. Arguments are passed through to the script.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0xiaochuan-remote.ps1" -FromBat %*
