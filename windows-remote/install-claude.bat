@echo off
rem Double-click to download and install the Claude Code CLI so "claude" works in any command window. Arguments are passed through to the script.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-claude.ps1" -FromBat %*
