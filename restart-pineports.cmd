@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\pineports.ps1" restart
if errorlevel 1 pause
