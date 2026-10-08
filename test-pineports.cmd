@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\pineports.ps1" test
set "code=%errorlevel%"
pause
exit /b %code%
