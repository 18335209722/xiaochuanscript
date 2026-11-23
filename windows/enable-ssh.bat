@echo off
rem Double-click to turn on the OpenSSH server so this PC can be reached over SSH. Arguments are passed through to the script.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0enable-ssh.ps1" -FromBat %*
