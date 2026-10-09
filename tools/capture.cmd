@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0run_capture.ps1" %*
pause
