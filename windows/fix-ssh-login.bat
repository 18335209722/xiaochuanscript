@echo off
rem Double-click to diagnose and fix SSH login problems on this PC. Arguments are passed through to the script.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-ssh-login.ps1" -FromBat %*
