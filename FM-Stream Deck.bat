@echo off
rem FM-Stream Deck - starts the local network server and opens the management panel.
rem Options: -Port 8080  -ObsPort 4455  -NoFirewall  -RemoveFirewall  -NoPanel
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server\server.ps1" %*
if errorlevel 1 pause
