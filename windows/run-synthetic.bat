@echo off
rem Double-click to run the synthetic benchmark. Add -Quick for a short run.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0synthetic-test.ps1" %*
echo.
pause
